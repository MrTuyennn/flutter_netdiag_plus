package dev.netdiag.flutter_netdiag_plus

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Đăng ký kênh traceroute native (ICMP ping-socket qua NDK) — dùng làm
 * fallback khi Dart-side không exec được binary `ping` (một số ROM chặn
 * execve). Xem android/src/main/cpp/traceroute.c.
 */
class FlutterNetdiagPlusPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var executor: ExecutorService
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        executor = Executors.newSingleThreadExecutor()
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_netdiag_plus/traceroute_android")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        if (call.method != "trace") {
            result.notImplemented()
            return
        }

        val host = call.argument<String>("host") ?: ""
        val maxHops = call.argument<Int>("maxHops") ?: 30
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 1500

        if (host.isEmpty()) {
            result.error("BAD_ARGS", "Thiếu host", null)
            return
        }

        executor.execute {
            try {
                val json = TracerouteNative.nativeTrace(host, maxHops, timeoutMs)
                mainHandler.post { result.success(json) }
            } catch (e: Throwable) {
                mainHandler.post { result.error("TRACE_FAILED", e.message, null) }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
