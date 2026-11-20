// Copyright (c) Sendspin for Mac authors
// Licensed under the Apache License, Version 2.0 (see Driver/LICENSE-sendspin).
// Modified for Fidelis.
//
// Audio Server plug-in providing the "Fidelis" output device. Apps play into it; the
// Fidelis app reads the same audio back (device property 'fdau'), encodes it as LDAC and
// sends it to the headphones over Bluetooth.

#include "LoopbackHandler.hpp"
#include "LoopbackStream.hpp"
#include "FidelisDevice.hpp"

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <algorithm>
#include <climits>
#include <string>

namespace {

constexpr UInt32 DefaultSampleRate = 48000;
constexpr UInt32 ChannelCount = 2;

// Custom device property 'fdlu': output presentation latency in µs (CFNumber), set by the
// Fidelis app to the Bluetooth path's delay (its buffer plus the headphones' delay report).
constexpr AudioObjectPropertySelector PresentationLatencySelector = 'fdlu';
constexpr SInt32 MaxPresentationLatencyUs = 5'000'000;

// This plug-in's bundle, wherever it's installed.
CFBundleRef DriverBundle()
{
    return CFBundleGetBundleWithIdentifier(CFSTR("dev.fidelis.driver"));
}

// file:// URL of the device icon inside this plug-in's bundle.
std::string IconURL()
{
    CFBundleRef bundle = DriverBundle();
    if (!bundle) {
        return "";
    }
    CFURLRef relative = CFBundleCopyResourceURL(bundle, CFSTR("FidelisDevice"), CFSTR("icns"), nullptr);
    if (!relative) {
        return "";
    }
    CFURLRef url = CFURLCopyAbsoluteURL(relative);
    CFRelease(relative);
    char buffer[PATH_MAX * 2] = {};
    const bool ok = CFStringGetCString(CFURLGetString(url), buffer, sizeof(buffer), kCFStringEncodingUTF8);
    CFRelease(url);
    return ok ? buffer : "";
}

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = "Fidelis";
    deviceParams.Manufacturer = "Fidelis";
    deviceParams.DeviceUID = "dev.fidelis.device";
    deviceParams.ModelUID = "dev.fidelis.model";
    deviceParams.FirmwareVersion = DRIVER_VERSION;
    deviceParams.ConfigurationApplicationBundleID = "dev.fidelis.app";
    deviceParams.IconURL = IconURL();
    deviceParams.SampleRate = DefaultSampleRate;
    deviceParams.ChannelCount = ChannelCount;
    deviceParams.CanBeDefault = true;
    // Personal headphones: alerts may follow the output there, as they do for AirPods.
    deviceParams.CanBeDefaultForSystemSounds = true;

    auto handler = std::make_shared<fidelis::LoopbackHandler>(ChannelCount);
    auto device = std::make_shared<fidelis::FidelisDevice>(context, deviceParams, handler, DriverBundle());

    // The app switches the rate to match the stream it sends to the speakers.
    std::vector<AudioValueRange> rates;
    for (Float64 rate : fidelis::SupportedSampleRates) {
        rates.push_back({rate, rate});
    }
    device->SetAvailableSampleRatesAsync(rates);

    // Output with volume + mute, so the volume keys and Control Center work. libASPL applies
    // both to the mixed float output (the default OnProcessMixedOutput); without AVRCP
    // absolute volume the headphones can't do it for us.
    aspl::StreamParameters outputParams;
    outputParams.Direction = aspl::Direction::Output;
    outputParams.Format = fidelis::Float32Format(DefaultSampleRate, ChannelCount);
    auto outputStream = std::make_shared<fidelis::LoopbackStream>(context, device, outputParams);
    device->AddStreamAsync(outputStream);
    outputStream->AttachVolumeControl(device->AddVolumeControlAsync(kAudioObjectPropertyScopeOutput));
    outputStream->AttachMuteControl(device->AddMuteControlAsync(kAudioObjectPropertyScopeOutput));

    // The app sets how far behind the headphones play (its buffer + their delay), and we report it
    // as output latency, so video players delay the picture to keep lip sync.
    std::weak_ptr<fidelis::LoopbackStream> weakOutput = outputStream;
    device->RegisterCustomProperty(
        PresentationLatencySelector,
        [weakOutput]() -> CFPropertyListRef {
            auto stream = weakOutput.lock();
            SInt32 latencyUs = stream ? SInt32(stream->GetPresentationLatencyUs()) : 0;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &latencyUs);
        },
        [weakOutput](CFPropertyListRef value) {
            SInt32 latencyUs = 0;
            if (!value || CFGetTypeID(value) != CFNumberGetTypeID() ||
                !CFNumberGetValue(CFNumberRef(value), kCFNumberSInt32Type, &latencyUs)) {
                return;
            }
            if (auto stream = weakOutput.lock()) {
                stream->SetPresentationLatencyUs(UInt32(std::clamp<SInt32>(latencyUs, 0, MaxPresentationLatencyUs)));
            }
        });

    // No input stream: the app reads the audio through 'fdau', so the device is a
    // speaker only, and nothing needs microphone access to stream it.
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* FidelisDriverEntryPoint(CFAllocatorRef, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    // Static, so the driver and its object tree live as long as the plug-in.
    static std::shared_ptr<aspl::Driver> driver = CreateDriver();

    return driver->GetReference();
}
