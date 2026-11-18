// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "../../GenericAvcProtocol.hpp"
#include "EnsembleControls.hpp"

namespace ASFW::Audio::BeBoB::Apogee {
// Retains the existing generic AV/C discovery and streaming behavior. The only
// addition is the device-specific provider consumed by ControlService.
class EnsembleProtocol final : public GenericAvcProtocol {
public:
    using GenericAvcProtocol::GenericAvcProtocol;
    const char* GetName() const override { return "Apogee Ensemble FireWire"; }
    Controls::IControlProvider* Controls() noexcept override { return &controls_; }
    void UpdateRuntimeContext(const Discovery::DeviceRouteToken& route,
                              std::shared_ptr<AVC::IAvcUnit> unit) override {
        controls_.Bind(route, unit);
        GenericAvcProtocol::UpdateRuntimeContext(route, std::move(unit));
    }
    IOReturn Shutdown() override {
        controls_.Bind({}, nullptr);
        return GenericAvcProtocol::Shutdown();
    }
private:
    EnsembleControls controls_;
};
} // namespace ASFW::Audio::BeBoB::Apogee
