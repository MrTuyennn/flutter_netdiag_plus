package dev.netdiag.flutter_netdiag_plus

/** Bridge sang libtraceroute.so (android/src/main/cpp/traceroute.c). */
object TracerouteNative {
    init {
        System.loadLibrary("traceroute")
    }

    /** Trả về JSON: mảng hop hoặc {"error": "..."}. Chạy blocking — gọi từ background thread. */
    external fun nativeTrace(host: String, maxHops: Int, timeoutMs: Int): String
}
