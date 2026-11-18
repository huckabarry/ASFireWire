// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 ASFireWire Project

#pragma once

#include "CatalogHelpers.hpp"

#include <array>

namespace ASFW::DeviceProfiles::Audio::Definitions {

inline constexpr std::array kApogeeDefinitions{
    // Preserve the generic AV/C geometry/rate/stream policy that already works
    // on Ensemble. The factory adds only its native controls provider.
    Definition(DeviceDefinitionId::ApogeeEnsemble, kApogeeVendorId, 0x01eeee,
               AudioFamilyProviderId::GenericAvc, ProbePolicyId::GenericAvc,
               ProfileBuilderId::GenericAvc, ProtocolImplementationId::GenericAvc,
               SupportDisposition::Supported, kApogeeVendorName, "Ensemble FireWire"),
    Definition(DeviceDefinitionId::ApogeeDuet, kApogeeVendorId, kApogeeDuetModelId,
               AudioFamilyProviderId::OXFW, ProbePolicyId::OxfwAvc,
               ProfileBuilderId::ApogeeDuet,
               ProtocolImplementationId::ApogeeDuet,
               SupportDisposition::Supported,
               kApogeeVendorName, kApogeeDuetModelName, std::nullopt,
               BootloaderCuePolicy::None,
               // Discovery reports and supports non-blocking, and host playback
               // works that way, but the observed device output cadence is
               // blocking -- forcing it keeps host and device aligned.
               DeviceStreamTraits{.wire = {.forcedStreamMode = ForcedStreamMode::Blocking},
                                  .resource = {.irmChannelMask = kAnyIsoChannel},
                                  .start = {.startShape = StreamStartShape::ApogeeInterleaved}}),
};

} // namespace ASFW::DeviceProfiles::Audio::Definitions
