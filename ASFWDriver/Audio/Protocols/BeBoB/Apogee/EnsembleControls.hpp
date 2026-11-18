// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "../../../Controls/IControlProvider.hpp"
#include "../../../../Protocols/AVC/Core/IAvcUnit.hpp"
#include <algorithm>
#include <array>
#include <memory>

namespace ASFW::Audio::BeBoB::Apogee {
namespace EnsembleControl {
inline constexpr uint32_t PhantomOn = 0x454e0010;
inline constexpr uint32_t PhantomOff = 0x454e0020;

// Behavioral reference: ALSA snd-firewire-ctl-services,
// protocols/bebob/src/apogee/ensemble.rs:1272-1274,1679-1688.
// E5 takes a zero-based mic index and boolean. Padding to 12 total bytes is
// mandatory: the reference warns that shorter commands can freeze the device.
inline std::optional<std::array<uint8_t, 9>> Operands(AudioModel::ParameterId id) {
    const bool on = id.value >= PhantomOn && id.value < PhantomOn + 4;
    const bool off = id.value >= PhantomOff && id.value < PhantomOff + 4;
    if (!on && !off) return std::nullopt;
    return std::array<uint8_t, 9>{0x00, 0x03, 0xdb, 0xe5,
        static_cast<uint8_t>(id.value - (on ? PhantomOn : PhantomOff)),
        static_cast<uint8_t>(on), 0xff, 0xff, 0xff};
}

inline bool Accepted(const AVC::Response& response, std::span<const uint8_t> request) {
    // Require the complete echo observed on hardware; do not accept a partial
    // echo or infer physical state from ACCEPTED.
    return response.code == AVC::ResponseCode::kAccepted &&
        response.address.Byte() == 0xff && static_cast<uint8_t>(response.opcode) == 0 &&
        response.operands.size() == request.size() &&
        std::equal(request.begin(), request.end(), response.operands.begin());
}

inline Controls::ControlSnapshot Snapshot(uint64_t revision) {
    namespace AM = AudioModel;
    Controls::ControlSnapshot result;
    result.family = "ensemble";
    result.topology.revision = result.state.topologyRevision = revision;
    for (uint32_t ch = 0; ch < 4; ++ch) {
        const AM::NodeId node{ch + 1};
        const AM::PortId port{ch + 1};
        result.topology.nodes.push_back({node, "Mic " + std::to_string(ch + 1),
            AM::EndpointNode{AM::EndpointKind::Physical}});
        result.topology.ports.push_back({port, node, AM::PortDirection::Output, 1,
            "XLR", {AM::SignalKind::AnalogMicXlr, ch + 1}});
        for (bool on : {true, false}) {
            result.topology.parameters.push_back({AM::ParameterId{(on ? PhantomOn : PhantomOff) + ch},
                port, AM::ParameterSemantic::PhantomPower, AM::ActionDomain{},
                "Mic " + std::to_string(ch + 1) + (on ? " 48V On" : " 48V Off")});
        }
    }
    // No remembered state: ALSA ensemble.rs:879-907 writes cached parameters;
    // HwStatus metering (1011-1051) does not establish phantom/input-mode readback.
    return result;
}
} // namespace EnsembleControl

// Controller-queue-only provider. It publishes native action parameters and
// never sends I/O during construction, Prepare, CopySnapshot, or binding.
class EnsembleControls final : public Controls::IControlProvider {
public:
    void Bind(const Discovery::DeviceRouteToken& route, std::shared_ptr<AVC::IAvcUnit> unit) {
        if (state_->route == route && state_->unit == unit) return;
        state_->active = false;
        state_ = std::make_shared<State>();
        state_->route = route;
        state_->unit = std::move(unit);
    }
    ~EnsembleControls() override { state_->active = false; }

    std::optional<Controls::ControlSnapshot> CopySnapshot() const override {
        if (!Current(*state_)) return std::nullopt;
        return EnsembleControl::Snapshot(state_->route.routeEpoch);
    }

    void SetParameter(AudioModel::ParameterId id, const AudioModel::ParameterValue& value,
                      Completion done) override {
        const auto state = state_;
        const auto operands = EnsembleControl::Operands(id);
        if (!operands || !std::holds_alternative<AudioModel::ActionTrigger>(value)) {
            done(kIOReturnBadArgument, false); return;
        }
        if (!Current(*state)) { done(kIOReturnNotReady, false); return; }
        // No deferred phantom writes: an overlapping request must be retried
        // explicitly by the user, never replayed after a reset or timeout.
        if (state->busy) { done(kIOReturnBusy, false); return; }
        const auto frame = AVC::CommandFrame::Make(AVC::CommandType::kControl,
            AVC::SubunitAddress::FromByte(0xff), static_cast<AVC::Opcode>(0), *operands);
        if (!frame) { done(kIOReturnBadArgument, false); return; }
        state->busy = true;
        state->unit->Submit(*frame, state->route.generation,
            [weak = std::weak_ptr<State>(state), operands, done = std::move(done)](AVC::Expected<AVC::Response> response) {
                const auto state = weak.lock();
                if (!state) { done(kIOReturnAborted, false); return; }
                state->busy = false;
                if (!Current(*state)) { done(kIOReturnAborted, false); return; }
                if (!response) { done(AVC::ToIOReturn(response.error()), false); return; }
                if (!EnsembleControl::Accepted(*response, *operands)) { done(kIOReturnError, false); return; }
                done(kIOReturnSuccess, AudioModel::ActionTrigger{});
            });
    }
private:
    struct State {
        Discovery::DeviceRouteToken route{};
        std::shared_ptr<AVC::IAvcUnit> unit;
        bool active{true};
        bool busy{false};
    };
    static bool Current(const State& state) {
        return state.active && state.route && state.unit &&
            state.unit->Guid() == state.route.guid &&
            state.unit->NodeId().value == FW::NodeNumberOf(state.route.nodeId) &&
            state.unit->IsCurrentRoute(state.route);
    }
    std::shared_ptr<State> state_{std::make_shared<State>()};
};
} // namespace ASFW::Audio::BeBoB::Apogee
