package com.cablebee.assistant

import android.content.Intent
import android.hardware.usb.UsbManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import android.util.Log
import java.io.File
import java.io.FileOutputStream

private const val TAG = "CableBee"

class MainActivity : FlutterActivity() {

    companion object {
        private const val USB_CHANNEL = "com.cablebee/usb"
        private const val USB_EVENTS  = "com.cablebee/usb_events"
        private const val ADB_CHANNEL = "com.cablebee/adb"
        private const val ADB_PORT    = 5037
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var usbEventSink: EventChannel.EventSink? = null

    // adb 二进制路径（files/adb）
    private lateinit var adbBin: File
    private lateinit var adbHome: File   // HOME 目录，key 存在此目录下的 .android/

    // 已"连接"的 serial 集合（逻辑层管理）
    private val connectedSerials = mutableSetOf<String>()

    // ── 初始化：从 assets 解压 adb 到 files/，chmod +x ─────────────────────

    private fun extractBinaries() {
        adbHome = filesDir          // HOME=/data/user/0/包名/files/../ → 实际用 filesDir
        adbBin  = File(filesDir, "adb")

        // 只在文件不存在或版本更新时解压
        if (!adbBin.exists() || adbBin.length() == 0L) {
            Log.i(TAG, "Extracting adb binary...")
            assets.open("adb").use { inp ->
                FileOutputStream(adbBin).use { out -> inp.copyTo(out) }
            }
        }
        // fastboot 也解压
        val fastbootBin = File(filesDir, "fastboot")
        if (!fastbootBin.exists() || fastbootBin.length() == 0L) {
            assets.open("fastboot").use { inp ->
                FileOutputStream(fastbootBin).use { out -> inp.copyTo(out) }
            }
        }
        // chmod +x
        Runtime.getRuntime().exec(arrayOf("chmod", "755", adbBin.absolutePath)).waitFor()
        Runtime.getRuntime().exec(arrayOf("chmod", "755", fastbootBin.absolutePath)).waitFor()
        Log.i(TAG, "adb binary ready: ${adbBin.absolutePath} (${adbBin.length()} bytes)")
    }

    // ── 启动 adb server ──────────────────────────────────────────────────────

    private fun startAdbServer() {
        try {
            // 检查 server 是否已经在跑
            val check = adb("devices")
            if (check.exit == 0) {
                Log.i(TAG, "adb server already running")
                return
            }
        } catch (_: Exception) {}

        Log.i(TAG, "Starting adb server...")
        // 和甲壳虫完全一样的启动方式
        ProcessBuilder(
            adbBin.absolutePath,
            "-L", "tcp:$ADB_PORT",
            "fork-server", "server",
            "--reply-fd", "4"
        ).apply {
            environment()["HOME"] = filesDir.absolutePath
            environment()["TMPDIR"] = cacheDir.absolutePath
        }.start()   // 不等待，后台持续运行

        // 等 server 就绪
        repeat(10) {
            Thread.sleep(200)
            try {
                if (adb("devices").exit == 0) {
                    Log.i(TAG, "adb server started")
                    return
                }
            } catch (_: Exception) {}
        }
        Log.w(TAG, "adb server may not have started properly")
    }

    // ── 执行 adb 命令（通过 -L 连接本地 server）─────────────────────────────

    private data class AdbResult(val exit: Int, val stdout: String, val stderr: String) {
        val isSuccess get() = exit == 0 || stdout.isNotEmpty()
        val output get() = (stdout + stderr).trim()
    }

    private fun adb(vararg args: String, timeoutMs: Long = 15_000): AdbResult {
        val cmd = mutableListOf(
            adbBin.absolutePath,
            "-L", "tcp:$ADB_PORT"   // 连接本地 server，和甲壳虫一样
        ) + args.toList()
        Log.d(TAG, "exec: ${cmd.joinToString(" ")}")

        val proc = ProcessBuilder(cmd).apply {
            environment()["HOME"]   = filesDir.absolutePath
            environment()["TMPDIR"] = cacheDir.absolutePath
        }.redirectErrorStream(false).start()

        // 异步读避免缓冲区死锁
        val stdoutJob = scope.async { proc.inputStream.bufferedReader().readText() }
        val stderrJob = scope.async { proc.errorStream.bufferedReader().readText() }

        val exited = proc.waitFor(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        if (!exited) proc.destroyForcibly()

        val stdout = runBlocking { stdoutJob.await() }
        val stderr = runBlocking { stderrJob.await() }
        val exit   = if (exited) proc.exitValue() else 1

        Log.d(TAG, "exit=$exit stdout=${stdout.take(300)} stderr=${stderr.take(300)}")
        return AdbResult(exit, stdout, stderr)
    }

    private fun ui(block: () -> Unit) = mainExecutor.execute(block)

    // ── Flutter Engine 配置 ──────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 初始化（在主线程外执行）
        scope.launch {
            try {
                extractBinaries()
                startAdbServer()
            } catch (e: Exception) {
                Log.e(TAG, "Init error: ${e.message}")
            }
        }

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

                    // getNativeLibraryDir → String（保持兼容，BinaryManager 需要）
                    "getNativeLibraryDir" -> {
                        result.success(filesDir.absolutePath)
                    }

                    // connect(host, port) → serial
                    "connect" -> {
                        val host = call.argument<String>("host") ?: return@setMethodCallHandler result.error("BAD_ARG","host required",null)
                        val port = call.argument<Int>("port") ?: 5555
                        val serial = "$host:$port"
                        scope.launch {
                            // 确保 server 在跑
                            startAdbServer()
                            val r = adb("connect", serial, timeoutMs = 20_000)
                            val out = r.output.lowercase()
                            if (out.contains("connected") || out.contains("already connected")) {
                                connectedSerials.add(serial)
                                ui { result.success(serial) }
                            } else {
                                ui { result.error("CONNECT_FAILED", r.output, null) }
                            }
                        }
                    }

                    // disconnect(serial) → 软断开，保留 adb server 连接避免重新授权
                    "disconnect" -> {
                        val serial = call.argument<String>("serial") ?: return@setMethodCallHandler result.error("BAD_ARG","serial required",null)
                        scope.launch {
                            connectedSerials.remove(serial)
                            // 不调用 adb disconnect，保持 server 侧连接
                            // 下次 connect 同一 serial 时 server 直接复用，不触发授权弹窗
                            ui { result.success(null) }
                        }
                    }

                    // devices() → List<String>
                    "devices" -> {
                        scope.launch {
                            try {
                                val r = adb("devices")
                                val online = r.stdout.lines()
                                    .drop(1)
                                    .filter { it.contains("\tdevice") }
                                    .map { it.substringBefore("\t").trim() }
                                // 只返回我们主动连接过且 server 仍在线的设备
                                val connected = online.filter { connectedSerials.contains(it) }
                                ui { result.success(connected) }
                            } catch (e: Exception) {
                                ui { result.success(emptyList<String>()) }
                            }
                        }
                    }

                    // shell(serial, command, timeoutMs) → stdout
                    "shell" -> {
                        val serial  = call.argument<String>("serial")  ?: return@setMethodCallHandler result.error("BAD_ARG","serial required",null)
                        val command = call.argument<String>("command") ?: return@setMethodCallHandler result.error("BAD_ARG","command required",null)
                        val timeout = call.argument<Int>("timeoutMs")?.toLong() ?: 15_000L
                        scope.launch {
                            val r = adb("-s", serial, "shell", command, timeoutMs = timeout)
                            ui {
                                if (r.exit == 0 || r.stdout.isNotEmpty()) result.success(r.stdout)
                                else result.error("SHELL_FAILED", r.stderr, null)
                            }
                        }
                    }

                    // push(serial, localPath, remotePath)
                    "push" -> {
                        val serial     = call.argument<String>("serial")     ?: return@setMethodCallHandler result.error("BAD_ARG","serial required",null)
                        val localPath  = call.argument<String>("localPath")  ?: return@setMethodCallHandler result.error("BAD_ARG","localPath required",null)
                        val remotePath = call.argument<String>("remotePath") ?: return@setMethodCallHandler result.error("BAD_ARG","remotePath required",null)
                        scope.launch {
                            val r = adb("-s", serial, "push", localPath, remotePath, timeoutMs = 120_000)
                            ui {
                                if (r.exit == 0) result.success(null)
                                else result.error("PUSH_FAILED", r.output, null)
                            }
                        }
                    }

                    // pull(serial, remotePath, localPath)
                    "pull" -> {
                        val serial     = call.argument<String>("serial")     ?: return@setMethodCallHandler result.error("BAD_ARG","serial required",null)
                        val remotePath = call.argument<String>("remotePath") ?: return@setMethodCallHandler result.error("BAD_ARG","remotePath required",null)
                        val localPath  = call.argument<String>("localPath")  ?: return@setMethodCallHandler result.error("BAD_ARG","localPath required",null)
                        scope.launch {
                            val r = adb("-s", serial, "pull", remotePath, localPath, timeoutMs = 120_000)
                            ui {
                                if (r.exit == 0) result.success(null)
                                else result.error("PULL_FAILED", r.output, null)
                            }
                        }
                    }

                    // pair(host, port, code) → String
                    "pair" -> {
                        val host = call.argument<String>("host") ?: return@setMethodCallHandler result.error("BAD_ARG","host required",null)
                        val port = call.argument<Int>("port")    ?: return@setMethodCallHandler result.error("BAD_ARG","port required",null)
                        val code = call.argument<String>("code") ?: return@setMethodCallHandler result.error("BAD_ARG","code required",null)
                        scope.launch {
                            try {
                                startAdbServer()
                                val proc = ProcessBuilder(
                                    adbBin.absolutePath, "-L", "tcp:$ADB_PORT",
                                    "pair", "$host:$port"
                                ).apply {
                                    environment()["HOME"]   = filesDir.absolutePath
                                    environment()["TMPDIR"] = cacheDir.absolutePath
                                    redirectErrorStream(true)
                                }.start()
                                // 发送配对码
                                proc.outputStream.bufferedWriter().use {
                                    it.write("$code\n"); it.flush()
                                }
                                val out = proc.inputStream.bufferedReader().readText()
                                proc.waitFor()
                                ui { result.success(out) }
                            } catch (e: Exception) {
                                ui { result.error("PAIR_FAILED", e.message, null) }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        when (intent.action) {
            UsbManager.ACTION_USB_DEVICE_ATTACHED -> usbEventSink?.success(mapOf("event" to "attached"))
            UsbManager.ACTION_USB_DEVICE_DETACHED -> usbEventSink?.success(mapOf("event" to "detached"))
        }
    }

    override fun onResume() { super.onResume(); intent?.let { onNewIntent(it) } }
    override fun onDestroy() { scope.cancel(); super.onDestroy() }
}
