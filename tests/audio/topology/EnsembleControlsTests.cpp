// SPDX-License-Identifier: Apache-2.0
#include "Audio/Protocols/BeBoB/Apogee/EnsembleControls.hpp"
#include "Audio/Controls/CoreAudioProjection.hpp"
#include "Audio/Model/Topology/Validate.hpp"
#include <gtest/gtest.h>

namespace {
using namespace ASFW;
using Audio::BeBoB::Apogee::EnsembleControls;
namespace EC = Audio::BeBoB::Apogee::EnsembleControl;
namespace AM = AudioModel;

class Unit final : public AVC::IAvcUnit {
public:
    Discovery::DeviceRouteToken route{0x0003db0500000001, 1, 7, FW::Generation{2}, 1};
    std::vector<std::vector<uint8_t>> frames;
    ResponseCallback pending;
    void Submit(const AVC::CommandFrame& frame, FW::Generation generation, ResponseCallback done) override {
        EXPECT_EQ(generation, route.generation);
        frames.emplace_back(frame.Bytes().begin(), frame.Bytes().end());
        pending = std::move(done);
    }
    FW::NodeId NodeId() const noexcept override { return FW::NodeId{static_cast<uint8_t>(route.nodeId)}; }
    FW::Generation CurrentGeneration() const noexcept override { return route.generation; }
    uint64_t Guid() const noexcept override { return route.guid; }
    std::optional<Discovery::DeviceRouteToken> CurrentRoute() const noexcept override { return route; }
    void Reply(std::vector<uint8_t> frame) {
        auto done = std::move(pending);
        ASSERT_TRUE(done);
        done(AVC::ParseResponse(frame));
    }
    void Accept() {
        auto response = frames.back(); response[0] = 9; Reply(response);
    }
};

struct EnsembleControlsTests : testing::Test {
    std::shared_ptr<Unit> unit = std::make_shared<Unit>();
    EnsembleControls controls;
    int completions = 0;
    IOReturn status = kIOReturnError;
    AM::ParameterValue result = false;
    void SetUp() override { controls.Bind(unit->route, unit); }
    void Write(uint32_t id = EC::PhantomOn + 3, AM::ParameterValue value = AM::ActionTrigger{}) {
        controls.SetParameter(AM::ParameterId{id}, value, [this](auto s, auto v) {
            ++completions; status = s; result = v;
        });
    }
};

TEST_F(EnsembleControlsTests, OpeningAndPreparingPublishesEightActionsWithoutHardwareIOOrInventedState) {
    controls.Prepare([&](auto s) { EXPECT_EQ(s, kIOReturnSuccess); });
    const auto snapshot = controls.CopySnapshot();
    ASSERT_TRUE(snapshot);
    EXPECT_TRUE(AM::validate(snapshot->topology));
    EXPECT_TRUE(AM::validateState(snapshot->topology, snapshot->state));
    EXPECT_EQ(snapshot->topology.parameters.size(), 8U);
    EXPECT_EQ(snapshot->topology.nodes.size(), 4U);
    EXPECT_EQ(snapshot->topology.revision, unit->route.routeEpoch);
    EXPECT_TRUE(snapshot->state.parameters.empty());
    EXPECT_TRUE(Audio::Controls::ProjectCoreAudioControls(snapshot->topology, snapshot->state).empty());
    for (const auto& p : snapshot->topology.parameters) {
        EXPECT_TRUE(std::holds_alternative<AM::ActionDomain>(p.domain));
        EXPECT_EQ(p.semantic, AM::ParameterSemantic::PhantomPower);
        EXPECT_TRUE(AM::validateParameterWrite(snapshot->topology, snapshot->state, p.id, AM::ActionTrigger{}));
    }
    EXPECT_TRUE(unit->frames.empty());
}

TEST_F(EnsembleControlsTests, EveryActionSendsExactlyOnePaddedFrameAndReturnsActionNotBooleanState) {
    for (uint8_t ch = 0; ch < 4; ++ch) for (uint8_t on : {0, 1}) {
        Write((on ? EC::PhantomOn : EC::PhantomOff) + ch);
        EXPECT_EQ(unit->frames.back(), (std::vector<uint8_t>{0, 0xff, 0, 0, 3, 0xdb, 0xe5, ch, on, 0xff, 0xff, 0xff}));
        unit->Accept();
        EXPECT_EQ(status, kIOReturnSuccess);
        EXPECT_TRUE(std::holds_alternative<AM::ActionTrigger>(result));
        EXPECT_TRUE(controls.CopySnapshot()->state.parameters.empty());
    }
    EXPECT_EQ(unit->frames.size(), 8U); EXPECT_EQ(completions, 8);
}

TEST_F(EnsembleControlsTests, InvalidIdsAndNonActionValuesNeverSend) {
    for (auto id : {0U, EC::PhantomOn - 1, EC::PhantomOn + 4, EC::PhantomOff + 4}) {
        Write(id); EXPECT_EQ(status, kIOReturnBadArgument);
    }
    for (AM::ParameterValue v : {AM::ParameterValue{true}, AM::ParameterValue{int64_t{1}}, AM::ParameterValue{1.0}}) {
        Write(EC::PhantomOn, v); EXPECT_EQ(status, kIOReturnBadArgument);
    }
    EXPECT_TRUE(unit->frames.empty());
}

TEST_F(EnsembleControlsTests, PartialWrongAndRejectedEchoesFailWithoutRetry) {
    for (size_t size = 0; size < 12; ++size) {
        Write(); auto reply = unit->frames.back(); reply[0] = 9; reply.resize(size);
        unit->Reply(reply); EXPECT_NE(status, kIOReturnSuccess);
    }
    for (size_t index = 0; index < 12; ++index) {
        Write(); auto reply = unit->frames.back(); reply[0] = 9; reply[index] ^= 1;
        unit->Reply(reply); EXPECT_NE(status, kIOReturnSuccess);
    }
    EXPECT_EQ(unit->frames.size(), 24U); EXPECT_EQ(completions, 24);
}

TEST_F(EnsembleControlsTests, OverlappingActionsAreRefusedNotQueued) {
    Write(); Write(EC::PhantomOff + 3);
    EXPECT_EQ(status, kIOReturnBusy); EXPECT_EQ(unit->frames.size(), 1U);
    unit->Accept(); EXPECT_EQ(status, kIOReturnSuccess);
    EXPECT_EQ(completions, 2); EXPECT_EQ(unit->frames.size(), 1U);
}

TEST_F(EnsembleControlsTests, TimeoutNeverResubmitsOrPublishesState) {
    Write(); auto done = std::move(unit->pending);
    done(std::unexpected(AVC::AvcError::Of(AVC::AvcErrorKind::kTimeout)));
    EXPECT_EQ(status, kIOReturnTimeout); EXPECT_EQ(unit->frames.size(), 1U);
    EXPECT_TRUE(controls.CopySnapshot()->state.parameters.empty());
}

TEST_F(EnsembleControlsTests, RebindAbortsOldCompletionWithoutClearingNewBusyState) {
    Write(); auto old = std::move(unit->pending);
    unit->route.routeEpoch++; controls.Bind(unit->route, unit);
    Write(); auto reply = unit->frames.back(); reply[0] = 9;
    old(AVC::ParseResponse(reply)); EXPECT_EQ(status, kIOReturnAborted);
    Write(); EXPECT_EQ(status, kIOReturnBusy);
    unit->Accept(); EXPECT_EQ(status, kIOReturnSuccess);
    EXPECT_EQ(unit->frames.size(), 2U);
}

TEST_F(EnsembleControlsTests, RouteChangeWithoutRebindHidesSnapshotAndRejectsWritesAndLateSuccess) {
    Write(); unit->route.deviceIncarnation++;
    EXPECT_FALSE(controls.CopySnapshot());
    unit->Accept(); EXPECT_EQ(status, kIOReturnAborted);
    Write(); EXPECT_EQ(status, kIOReturnNotReady); EXPECT_EQ(unit->frames.size(), 1U);
}

TEST_F(EnsembleControlsTests, DisconnectAndProviderDestructionAbortLateCompletion) {
    Write(); controls.Bind({}, nullptr);
    EXPECT_FALSE(controls.CopySnapshot());
    unit->Accept(); EXPECT_EQ(status, kIOReturnAborted);
    {
        EnsembleControls temporary; temporary.Bind(unit->route, unit);
        temporary.SetParameter(AM::ParameterId{EC::PhantomOn}, AM::ActionTrigger{},
            [&](auto s, auto) { status = s; });
    }
    unit->Accept(); EXPECT_EQ(status, kIOReturnAborted);
}
} // namespace
