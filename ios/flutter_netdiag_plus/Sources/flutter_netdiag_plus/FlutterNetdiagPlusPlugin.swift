import Flutter
import UIKit

public class FlutterNetdiagPlusPlugin: NSObject, FlutterPlugin {
    private static let tracerouteChannel = "flutter_netdiag_plus/traceroute"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: tracerouteChannel,
            binaryMessenger: registrar.messenger()
        )
        let instance = FlutterNetdiagPlusPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "trace" else {
            result(FlutterMethodNotImplemented)
            return
        }

        let arguments = call.arguments as? [String: Any] ?? [:]
        let host = arguments["host"] as? String ?? ""
        let maxHops = arguments["maxHops"] as? Int ?? 30
        let timeoutMs = arguments["timeoutMs"] as? Int ?? 1500

        guard !host.isEmpty else {
            result(FlutterError(code: "BAD_ARGS", message: "Thiếu host", details: nil))
            return
        }

        // Traceroute chặn luồng (recvfrom blocking) nên phải chạy nền, không
        // được chạy trên main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let hops = try Traceroute(
                    host: host,
                    maxHops: maxHops,
                    perHopTimeout: Double(timeoutMs) / 1000.0
                ).run()

                let payload = hops.map { $0.asDictionary }
                DispatchQueue.main.async { result(payload) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "TRACE_FAILED",
                        message: "\(error)",
                        details: nil
                    ))
                }
            }
        }
    }
}
