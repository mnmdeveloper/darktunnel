#!/usr/bin/env python3
from pathlib import Path

path = Path("PacketTunnel/PacketTunnelProvider.swift")
text = path.read_text(encoding="utf-8")

old = r'''                    let handle = resolvedUAPI.withCString { awgTurnOn($0, descriptor) }
                    guard handle >= 0 else {
                        completionHandler(TunnelError.amneziaBackendFailed(handle))
                        return
                    }
                    self.amneziaHandle = handle
                    let versionPointer = awgVersion()
                    let version = versionPointer == nil ? "unknown" : String(cString: versionPointer!)
                    self.logger.notice("AmneziaWG backend started: \(version), endpoint \(resolved.host)")
                    awgDisableSomeRoamingForBrokenMobileSemantics(handle)
                    completionHandler(nil)
'''

new = r'''                    // awgTurnOn performs native Go socket/configuration work and must
                    // not run on the PacketTunnel main queue. Calling it here can block
                    // the extension before it invokes completionHandler, leaving iOS in
                    // an endless "Connecting..." state.
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }

                        let handle = resolvedUAPI.withCString { awgTurnOn($0, descriptor) }
                        guard handle >= 0 else {
                            DispatchQueue.main.async {
                                completionHandler(TunnelError.amneziaBackendFailed(handle))
                            }
                            return
                        }

                        let versionPointer = awgVersion()
                        let version = versionPointer == nil ? "unknown" : String(cString: versionPointer!)
                        awgDisableSomeRoamingForBrokenMobileSemantics(handle)

                        DispatchQueue.main.async {
                            self.amneziaHandle = handle
                            self.logger.notice("AmneziaWG backend started: \(version), endpoint \(resolved.host)")
                            completionHandler(nil)
                        }
                    }
'''

if old not in text:
    raise SystemExit("Expected AmneziaWG startup block not found")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
print("Patched AmneziaWG startup to run awgTurnOn off the main queue.")
