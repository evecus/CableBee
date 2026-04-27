package com.cablebee.assistant

import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import android.util.Log
import java.io.File
import java.util.concurrent.TimeUnit

private const val TAG = "CableBee"

class MainActivity : FlutterActivity() {

    companion object {
        private const val USB_CHANNEL        = "com.cablebee/usb"
        private const val USB_EVENTS         = "com.cablebee/usb_events"
        private const val ADB_CHANNEL        = "com.cablebee/adb"
        private const val LOCAL_APPS_CHANNEL = "com.cablebee.assistant/local_apps"
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var usbEventSink: EventChannel.EventSink? = null

    private lateinit var adbBin: File
    private lateinit var fastbootBin: File

    private val connectedSerials = mutableSetOf<String>()

    // ── 初始化二进制路径 ──────────────────────────────────────────────────────

    private fun initBinaries() {
        val nativeDir = applicationInfo.nativeLibraryDir
        adbBin      = File(nativeDir, "libcablebee_adb.so")
        fastbootBin = File(nativeDir, "libcablebee_fastboot.so")
        Log.i(TAG, "adb: ${adbBin.absolutePath} exists=${adbBin.exists()} size=${adbBin.length()}")
        Log.i(TAG, "fastboot: ${fastbootBin.absolutePath} exists=${fastbootBin.exists()}")
    }

    // ── 核心执行函数 ──────────────────────────────────────────────────────────
    //
    // 去掉 "-L tcp:5037"，不再依赖本地 adb server。
    // adb 二进制直接以客户端模式运行，对每个命令建立独立连接。
    // 彻底绕过 start-server/fork，解决 OPPO/一加 SELinux 限制。

    private data class AdbResult(val exit: Int, val stdout: String, val stderr: String) {
        val isSuccess get() = exit == 0 || stdout.isNotEmpty()
        val output    get() = (stdout + stderr).trim()
    }

    private fun adb(vararg args: String, timeoutMs: Long = 15_000): AdbResult {
        val cmd = mutableListOf(adbBin.absolutePath) + args.toList()
        Log.d(TAG, "exec: ${cmd.joinToString(" ")}")

        val proc = ProcessBuilder(cmd).apply {
            environment()["HOME"]                    = filesDir.absolutePath
            environment()["TMPDIR"]                  = cacheDir.absolutePath
            environment()["ANDROID_ADB_SERVER_PORT"] = "15037"
        }.redirectErrorStream(false).start()

        val stdoutBuf = StringBuilder()
        val stderrBuf = StringBuilder()

        val stdoutThread = Thread {
            try { stdoutBuf.append(proc.inputStream.bufferedReader().readText()) }
            catch (_: Exception) {}
        }.also { it.isDaemon = true; it.start() }

        val stderrThread = Thread {
            try { stderrBuf.append(proc.errorStream.bufferedReader().readText()) }
            catch (_: Exception) {}
        }.also { it.isDaemon = true; it.start() }

        val exited = proc.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
        if (!exited) {
            Log.w(TAG, "adb timeout after ${timeoutMs}ms, killing")
            proc.destroyForcibly()
        }

        stdoutThread.join(2_000)
        stderrThread.join(2_000)

        val stdout = stdoutBuf.toString()
        val stderr = stderrBuf.toString()
        val exit   = if (exited) runCatching { proc.exitValue() }.getOrDefault(1) else 1

        Log.d(TAG, "exit=$exit stdout=${stdout.take(200)} stderr=${stderr.take(200)}")
        return AdbResult(exit, stdout, stderr)
    }

    // pair 需要往 stdin 写配对码，单独处理
    private fun adbPair(host: String, port: Int, code: String, timeoutMs: Long = 30_000): AdbResult {
        val cmd = listOf(adbBin.absolutePath, "pair", "$host:$port")
        Log.d(TAG, "exec pair: ${cmd.joinToString(" ")}")

        val proc = ProcessBuilder(cmd).apply {
            environment()["HOME"]                    = filesDir.absolutePath
            environment()["TMPDIR"]                  = cacheDir.absolutePath
            environment()["ANDROID_ADB_SERVER_PORT"] = "15037"
            redirectErrorStream(true)
        }.start()

        try {
            proc.outputStream.bufferedWriter().use {
                it.write("$code\n"); it.flush()
            }
        } catch (e: Exception) {
            Log.w(TAG, "pair stdin write failed: ${e.message}")
        }

        val outBuf = StringBuilder()
        val readThread = Thread {
            try { outBuf.append(proc.inputStream.bufferedReader().readText()) }
            catch (_: Exception) {}
        }.also { it.isDaemon = true; it.start() }

        val exited = proc.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
        if (!exited) proc.destroyForcibly()
        readThread.join(2_000)

        val out  = outBuf.toString()
        val exit = if (exited) runCatching { proc.exitValue() }.getOrDefault(1) else 1
        Log.d(TAG, "pair exit=$exit out=${out.take(200)}")
        return AdbResult(exit, out, "")
    }

    private fun ui(block: () -> Unit) = mainExecutor.execute(block)

    // ── Flutter Engine 配置 ──────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        initBinaries()
        // 不再启动 adb server，直接用客户端模式

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

                    "getNativeLibraryDir" ->
                        result.success(applicationInfo.nativeLibraryDir)

                    // connect(host, port) → serial
                    "connect" -> {
                        val host   = call.argument<String>("host") ?: return@setMethodCallHandler result.error("BAD_ARG","host required",null)
                        val port   = call.argument<Int>("port") ?: 5555
                        val serial = "$host:$port"
                        scope.launch {
                            Log.i(TAG, "connect: $serial")
                            val r   = adb("connect", serial, timeoutMs = 20_000)
                            val out = r.output.lowercase()
                            when {
                                out.contains("connected") || out.contains("already connected") -> {
                                    connectedSerials.add(serial)
                                    Log.i(TAG, "connect OK: $serial")
                                    ui { result.success(serial) }
                                }
                                out.contains("offline") || out.contains("unauthorized") ||
                                out.contains("failed to authenticate") -> {
                                    Log.i(TAG, "connect: waiting for authorization on $serial")
                                    var authorized = false
                                    repeat(30) { attempt ->
                                        if (authorized) return@repeat
                                        Thread.sleep(1_000)
                                        if (attempt % 5 == 0) adb("connect", serial, timeoutMs = 5_000)
                                        val devOut = adb("devices", timeoutMs = 5_000).stdout
                                        if (devOut.lines().any { it.startsWith(serial) && it.contains("\tdevice") }) {
                                            authorized = true
                                            connectedSerials.add(serial)
                                            Log.i(TAG, "connect: authorized after ${attempt + 1}s")
                                            ui { result.success(serial) }
                                        }
                                    }
                                    if (!authorized) {
                                        ui { result.error("CONNECT_FAILED", "授权超时，请在设备上点击「允许 USB 调试」后重试", null) }
                                    }
                                }
                                else ->
                                    ui { result.error("CONNECT_FAILED", r.output, null) }
                            }
                        }
                    }

                    // disconnect(serial)
                    "disconnect" -> {
                        val serial = call.argument<String>("serial") ?: return@setMethodCallHandler result.error("BAD_ARG","serial required",null)
                        scope.launch {
                            connectedSerials.remove(serial)
                            adb("disconnect", serial, timeoutMs = 5_000)
                            ui { result.success(null) }
                        }
                    }

                    // devices() → List<String>
                    "devices" -> {
                        scope.launch {
                            try {
                                val r      = adb("devices", timeoutMs = 8_000)
                                val online = r.stdout.lines()
                                    .drop(1)
                                    .filter { it.contains("\tdevice") }
                                    .map { it.substringBefore("\t").trim() }
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
                                val r = adbPair(host, port, code)
                                ui { result.success(r.output) }
                            } catch (e: Exception) {
                                ui { result.error("PAIR_FAILED", e.message, null) }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // ── LOCAL APPS ────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCAL_APPS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // 返回本机已安装应用列表（包名、标签、APK路径，不含图标）
                    "getInstalledApps" -> {
                        scope.launch {
                            try {
                                val pm = packageManager
                                val packages = pm.getInstalledPackages(0)

                                val appList = packages.mapNotNull { pkgInfo ->
                                    try {
                                        val appInfo = pkgInfo.applicationInfo ?: return@mapNotNull null
                                        val label = pm.getApplicationLabel(appInfo).toString()
                                        val apkPath = appInfo.sourceDir ?: return@mapNotNull null
                                        mapOf(
                                            "packageName" to pkgInfo.packageName,
                                            "label"       to label,
                                            "apkPath"     to apkPath,
                                        )
                                    } catch (_: Exception) { null }
                                }

                                ui { result.success(appList) }
                            } catch (e: Exception) {
                                ui { result.error("GET_APPS_FAILED", e.message, null) }
                            }
                        }
                    }

                    // 将APK复制到 cacheDir，返回临时路径（用于权限受限路径）
                    "copyApkToTemp" -> {
                        val packageName = call.argument<String>("packageName")
                            ?: return@setMethodCallHandler result.error("BAD_ARG", "packageName required", null)
                        scope.launch {
                            try {
                                val pm = packageManager
                                val appInfo = pm.getApplicationInfo(packageName, 0)
                                val srcFile = File(appInfo.sourceDir)
                                val destDir = File(cacheDir, "apk_temp").also { it.mkdirs() }
                                val destFile = File(destDir, "$packageName.apk")

                                srcFile.inputStream().use { input ->
                                    destFile.outputStream().use { output ->
                                        input.copyTo(output)
                                    }
                                }

                                ui { result.success(destFile.absolutePath) }
                            } catch (e: Exception) {
                                ui { result.error("COPY_APK_FAILED", e.message, null) }
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
