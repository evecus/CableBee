package com.cablebee.assistant

import android.content.Intent
import android.hardware.usb.UsbManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*

class MainActivity : FlutterActivity() {

    companion object {
        private const val USB_CHANNEL = "com.cablebee/usb"
        private const val USB_EVENTS  = "com.cablebee/usb_events"
        private const val ADB_CHANNEL = "com.cablebee/adb"
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var usbEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Initialize persistent RSA key pair for ADB authentication
        AdbBridge.init(applicationContext.filesDir)

        // ── USB ───────────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, USB_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getConnectedUsbDevices" -> {
                        val mgr = getSystemService(USB_SERVICE) as UsbManager
                        result.success(mgr.deviceList.map { (name, d) ->
                            mapOf("name" to name, "vendorId" to d.vendorId,
                                  "productId" to d.productId, "deviceName" to d.deviceName,
                                  "serialNumber" to (runCatching { d.serialNumber }.getOrNull() ?: ""))
                        })
                    }
                    "hasUsbHostSupport" ->
                        result.success(packageManager.hasSystemFeature("android.hardware.usb.host"))
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, USB_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(a: Any?, s: EventChannel.EventSink?) { usbEventSink = s }
                override fun onCancel(a: Any?) { usbEventSink = null }
            })

        // ── ADB ───────────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ADB_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // getNativeLibraryDir() → String
                    // Returns the path where Android extracted our jniLibs .so files.
                    // BinaryManager uses this to locate libadb.so and libfastboot.so.
                    "getNativeLibraryDir" -> {
                        val dir = applicationInfo.nativeLibraryDir
                        result.success(dir)
                    }

                    // connect(host, port) → serial
                    "connect" -> {
                        val host = call.argument<String>("host") ?: return@setMethodCallHandler result.error("BAD_ARG","host required",null)
                        val port = call.argument<Int>("port") ?: 5555
                        scope.launch {
                            runCatching { AdbBridge.connect(host, port) }
                                .onSuccess  { ui { result.success(it) } }
                                .onFailure  { ui { result.error("CONNECT_FAILED", it.message, null) } }
                        }
                    }

                    // disconnect(serial)
                    "disconnect" -> {
                        val serial = call.argument<String>("serial") ?: return@setMethodCallHandler result.error("BAD_ARG","serial required",null)
                        scope.launch { AdbBridge.disconnect(serial); ui { result.success(null) } }
                    }

                    // devices() → List<String>
                    "devices" -> result.success(AdbBridge.devices())

                    // shell(serial, command, timeoutMs) → String
                    "shell" -> {
                        val serial  = call.argument<String>("serial")  ?: return@setMethodCallHandler result.error("BAD_ARG","serial required",null)
                        val command = call.argument<String>("command") ?: return@setMethodCallHandler result.error("BAD_ARG","command required",null)
                        val timeout = call.argument<Int>("timeoutMs")?.toLong() ?: 15_000L
                        scope.launch {
                            runCatching { AdbBridge.shell(serial, command, timeout) }
                                .onSuccess  { ui { result.success(it) } }
                                .onFailure  { ui { result.error("SHELL_FAILED", it.message, null) } }
                        }
                    }

                    // push(serial, localPath, remotePath) → null or error
                    "push" -> {
                        val serial     = call.argument<String>("serial")     ?: return@setMethodCallHandler result.error("BAD_ARG","serial required",null)
                        val localPath  = call.argument<String>("localPath")  ?: return@setMethodCallHandler result.error("BAD_ARG","localPath required",null)
                        val remotePath = call.argument<String>("remotePath") ?: return@setMethodCallHandler result.error("BAD_ARG","remotePath required",null)
                        scope.launch {
                            runCatching { AdbBridge.push(serial, localPath, remotePath) }
                                .onSuccess  { r ->
                                    if (r.success) ui { result.success(null) }
                                    else           ui { result.error("PUSH_FAILED", r.error, null) }
                                }
                                .onFailure  { ui { result.error("PUSH_FAILED", it.message, null) } }
                        }
                    }

                    // pull(serial, remotePath, localPath) → null or error
                    "pull" -> {
                        val serial     = call.argument<String>("serial")     ?: return@setMethodCallHandler result.error("BAD_ARG","serial required",null)
                        val remotePath = call.argument<String>("remotePath") ?: return@setMethodCallHandler result.error("BAD_ARG","remotePath required",null)
                        val localPath  = call.argument<String>("localPath")  ?: return@setMethodCallHandler result.error("BAD_ARG","localPath required",null)
                        scope.launch {
                            runCatching { AdbBridge.pull(serial, remotePath, localPath) }
                                .onSuccess  { r ->
                                    if (r.success) ui { result.success(null) }
                                    else           ui { result.error("PULL_FAILED", r.error, null) }
                                }
                                .onFailure  { ui { result.error("PULL_FAILED", it.message, null) } }
                        }
                    }

                    // pair(host, port, code, adbBinPath) — SPAKE2 via adb binary (one-time)
                    "pair" -> {
                        val host = call.argument<String>("host") ?: return@setMethodCallHandler result.error("BAD_ARG","host required",null)
                        val port = call.argument<Int>("port")    ?: return@setMethodCallHandler result.error("BAD_ARG","port required",null)
                        val code = call.argument<String>("code") ?: return@setMethodCallHandler result.error("BAD_ARG","code required",null)
                        scope.launch {
                            // libadb.so is the adb binary in jniLibs, already chmod'd by BinaryManager
                            val bin = "${applicationInfo.nativeLibraryDir}/libadb.so"
                            runCatching {
                                val proc = ProcessBuilder(bin, "pair", "$host:$port")
                                    .redirectErrorStream(true).start()
                                proc.outputStream.bufferedWriter().use { it.write("$code\n"); it.flush() }
                                val out = proc.inputStream.bufferedReader().readText()
                                proc.waitFor()
                                out
                            }
                                .onSuccess  { ui { result.success(it) } }
                                .onFailure  { ui { result.error("PAIR_FAILED", it.message, null) } }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun ui(block: () -> Unit) = mainExecutor.execute(block)

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        when (intent.action) {
            UsbManager.ACTION_USB_DEVICE_ATTACHED -> usbEventSink?.success(mapOf("event" to "attached"))
            UsbManager.ACTION_USB_DEVICE_DETACHED -> usbEventSink?.success(mapOf("event" to "detached"))
        }
    }

    override fun onResume()  { super.onResume(); intent?.let { onNewIntent(it) } }
    override fun onDestroy() { scope.cancel(); AdbBridge.disconnectAll(); super.onDestroy() }
}
