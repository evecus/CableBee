package com.cablebee.assistant

import android.app.*
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.provider.Settings
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import android.util.Log
import java.io.File
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.util.concurrent.TimeUnit

private const val TAG = "CableBee"

class MainActivity : FlutterActivity() {

    companion object {
        private const val USB_CHANNEL        = "com.cablebee/usb"
        private const val USB_EVENTS         = "com.cablebee/usb_events"
        private const val ADB_CHANNEL        = "com.cablebee/adb"
        private const val FASTBOOT_CHANNEL   = "com.cablebee/fastboot"
        private const val SHELL_STREAM_EVENTS = "com.cablebee/shell_stream"
        private const val LOCAL_APPS_CHANNEL = "com.cablebee.assistant/local_apps"
        private const val SCRCPY_METHOD      = ScrcpyChannel.METHOD_CHANNEL
        private const val SCRCPY_EVENTS      = ScrcpyChannel.EVENT_CHANNEL

        // 配对本机新增
        private const val SELF_PAIR_EVENTS   = "com.cablebee/self_pair_events"
        private const val NOTIF_CHANNEL_ID   = "cablebee_self_pair"
        private const val NOTIF_ID           = 9001
        private const val NOTIF_REQ_REPLY    = 9002
        private const val NOTIF_REQ_CANCEL   = 9003
        private const val ACTION_PAIR_CODE   = "com.cablebee.ACTION_PAIR_CODE"
        private const val ACTION_CANCEL_PAIR = "com.cablebee.ACTION_CANCEL_PAIR"
        private const val EXTRA_CODE         = "pair_code"
        private const val EXTRA_PORT         = "pair_port"
        private const val EXTRA_PORT_INPUT   = "pair_port_input"  // 用户手动输入的端口
        private const val TLS_PAIRING_TYPE   = "_adb-tls-pairing._tcp"
        private const val TLS_CONNECT_TYPE   = "_adb-tls-connect._tcp"
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var usbEventSink: EventChannel.EventSink? = null
    private var selfPairEventSink: EventChannel.EventSink? = null
    private var scrcpyChannel: ScrcpyChannel? = null

    private lateinit var adbBin: File
    private lateinit var fastbootBin: File

    private val connectedSerials = mutableSetOf<String>()

    // ── mDNS 配对本机状态 ─────────────────────────────────────────────────────
    private var nsdManager: NsdManager? = null
    private var pairingDiscoveryListener: NsdManager.DiscoveryListener? = null
    private var connectDiscoveryListener: NsdManager.DiscoveryListener? = null
    private var discoveredPairPort: Int = -1
    private var discoveredConnectPort: Int = -1   // _adb-tls-connect 端口，adb connect 用这个
    private var selfPairingActive = false
    private var pairSucceeded = false  // 配对成功标志，onResume 时用来关闭成功通知

    // ── 初始化二进制路径 ──────────────────────────────────────────────────────

    private fun initBinaries() {
        val nativeDir = applicationInfo.nativeLibraryDir
        adbBin      = File(nativeDir, "libcablebee_adb.so")
        fastbootBin = File(nativeDir, "libcablebee_fastboot.so")
        Log.i(TAG, "adb: ${adbBin.absolutePath} exists=${adbBin.exists()} size=${adbBin.length()}")
        Log.i(TAG, "fastboot: ${fastbootBin.absolutePath} exists=${fastbootBin.exists()}")
    }

    // ── 核心 ADB 执行 ─────────────────────────────────────────────────────────

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

    // ── mDNS 配对本机 ─────────────────────────────────────────────────────────

    /** 检查端口是否真实有人在监听（绑定失败 = 端口被占用 = adbd 在此端口等待） */
    private fun isPortListening(port: Int): Boolean = try {
        ServerSocket().use {
            it.bind(InetSocketAddress("127.0.0.1", port), 1)
            false // 绑定成功说明没人用，端口无效
        }
    } catch (_: Exception) {
        true // 绑定失败说明端口已被占用，即服务在监听
    }

    /** 判断 NsdServiceInfo 解析的 host 是否属于本机网络接口 */
    private fun isLocalHost(hostAddress: String?): Boolean {
        if (hostAddress == null) return false
        if (hostAddress == "127.0.0.1") return true
        return try {
            NetworkInterface.getNetworkInterfaces()
                ?.asSequence()
                ?.flatMap { it.inetAddresses.asSequence() }
                ?.any { it.hostAddress == hostAddress }
                ?: false
        } catch (_: Exception) { false }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun startSelfPairDiscovery() {
        if (selfPairingActive) {
            Log.i(TAG, "selfPair: already active, skip")
            return
        }
        selfPairingActive = true
        discoveredPairPort = -1
        discoveredConnectPort = -1

        ensureNotifChannel()
        nsdManager = getSystemService(NsdManager::class.java)

        // 立刻发通知——端口未知，让用户手动填端口+配对码
        ui { showPairCodeNotification(port = -1) }

        // ── 监听配对端口 (_adb-tls-pairing._tcp) ─────────────────────────
        val pairingListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {
                Log.i(TAG, "selfPair: pairing discovery started")
            }
            override fun onStartDiscoveryFailed(type: String, code: Int) {
                Log.w(TAG, "selfPair: pairing discovery start failed code=$code")
            }
            override fun onDiscoveryStopped(type: String) {
                Log.i(TAG, "selfPair: pairing discovery stopped")
            }
            override fun onStopDiscoveryFailed(type: String, code: Int) {
                Log.w(TAG, "selfPair: pairing stop failed code=$code")
            }
            override fun onServiceFound(info: NsdServiceInfo) {
                Log.i(TAG, "selfPair: pairing service found ${info.serviceName}")
                nsdManager?.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(i: NsdServiceInfo, code: Int) {
                        Log.w(TAG, "selfPair: pairing resolve failed code=$code")
                    }
                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        val hostAddr = resolved.host?.hostAddress
                        val port = resolved.port
                        Log.i(TAG, "selfPair: pairing resolved host=$hostAddr port=$port")
                        if (isLocalHost(hostAddr) && isPortListening(port)) {
                            discoveredPairPort = port
                            Log.i(TAG, "selfPair: valid pairing port=$port, updating notification")
                            // 只在配对流程仍进行中时才更新通知，避免配对成功后又重新弹出
                            if (selfPairingActive) ui { showPairCodeNotification() }
                        }
                    }
                })
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                Log.i(TAG, "selfPair: pairing service lost")
            }
        }

        // ── 同时监听连接端口 (_adb-tls-connect._tcp) ──────────────────────
        // 无线调试开启后这个端口一直存在，pair 完成后直接用它 adb connect
        val connectListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {
                Log.i(TAG, "selfPair: connect discovery started")
            }
            override fun onStartDiscoveryFailed(type: String, code: Int) {
                Log.w(TAG, "selfPair: connect discovery start failed code=$code")
            }
            override fun onDiscoveryStopped(type: String) {
                Log.i(TAG, "selfPair: connect discovery stopped")
            }
            override fun onStopDiscoveryFailed(type: String, code: Int) {
                Log.w(TAG, "selfPair: connect stop failed code=$code")
            }
            override fun onServiceFound(info: NsdServiceInfo) {
                Log.i(TAG, "selfPair: connect service found ${info.serviceName}")
                nsdManager?.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(i: NsdServiceInfo, code: Int) {
                        Log.w(TAG, "selfPair: connect resolve failed code=$code")
                    }
                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        val hostAddr = resolved.host?.hostAddress
                        val port = resolved.port
                        Log.i(TAG, "selfPair: connect resolved host=$hostAddr port=$port")
                        if (isLocalHost(hostAddr) && isPortListening(port)) {
                            discoveredConnectPort = port
                            Log.i(TAG, "selfPair: valid connect port=$port (will use after pairing)")
                        }
                    }
                })
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                Log.i(TAG, "selfPair: connect service lost")
                if (discoveredConnectPort != -1) discoveredConnectPort = -1
            }
        }

        pairingDiscoveryListener = pairingListener
        connectDiscoveryListener = connectListener
        nsdManager?.discoverServices(TLS_PAIRING_TYPE, NsdManager.PROTOCOL_DNS_SD, pairingListener)
        nsdManager?.discoverServices(TLS_CONNECT_TYPE, NsdManager.PROTOCOL_DNS_SD, connectListener)

        // 跳转系统开发者选项无线调试页
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                putExtra(":settings:fragment_args_key", "toggle_adb_wireless")
            }
            startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "selfPair: failed to open dev settings: ${e.message}")
            try {
                startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                })
            } catch (_: Exception) {}
        }
    }

    private fun stopSelfPairDiscovery() {
        selfPairingActive = false
        pairingDiscoveryListener?.let {
            try { nsdManager?.stopServiceDiscovery(it) } catch (_: Exception) {}
        }
        pairingDiscoveryListener = null
        connectDiscoveryListener?.let {
            try { nsdManager?.stopServiceDiscovery(it) } catch (_: Exception) {}
        }
        connectDiscoveryListener = null
    }

    /** 用收到的配对码执行 adb pair，然后用已发现的 connect 端口通知 Flutter */
    private fun executeSelfPair(port: Int, code: String) {
        scope.launch {
            Log.i(TAG, "selfPair: executing adb pair 127.0.0.1:$port code=$code")
            val pairRes = adbPair("127.0.0.1", port, code, timeoutMs = 30_000)
            val ok = pairRes.output.contains("Successfully", ignoreCase = true)
            Log.i(TAG, "selfPair: pair result ok=$ok output=${pairRes.output}")

            if (ok) {
                // 优先用 mDNS 已发现的 connect 端口，没发现时降级用 adb devices 找
                val connectPort = if (discoveredConnectPort > 0) {
                    Log.i(TAG, "selfPair: using mDNS connect port=$discoveredConnectPort")
                    discoveredConnectPort
                } else {
                    Log.w(TAG, "selfPair: connect port not yet discovered, falling back to adb devices")
                    findConnectPortFromDevices()
                }
                stopSelfPairDiscovery()
                pairSucceeded = true
                showPairSuccessNotification()
                val finalPort = connectPort ?: 5555
                ui {
                    // 配对成功 → 把 App 拉到前台
                    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                        flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    if (launchIntent != null) startActivity(launchIntent)
                }
                // 等 App 回到前台、EventSink 就绪后再发事件
                delay(600)
                ui {
                    selfPairEventSink?.success(mapOf(
                        "type" to "success",
                        "message" to "配对成功",
                        "connectPort" to finalPort,
                    ))
                }
            } else {
                dismissNotification()
                ui {
                    selfPairEventSink?.success(mapOf(
                        "type" to "error",
                        "message" to pairRes.output.ifEmpty { "配对失败，请检查配对码" },
                    ))
                }
            }
        }
    }

    /**
     * 降级方案：pair 成功后 adb devices 里找已授权的 127.0.0.1:xxx。
     * 正常情况下 discoveredConnectPort 已由 mDNS 提前拿到，这个函数几乎用不到。
     */
    private fun findConnectPortFromDevices(): Int? {
        // pair 刚完成，adbd 可能还没把新密钥加进 authorized_keys，稍等一下
        Thread.sleep(1_000)
        val r = adb("devices", timeoutMs = 5_000)
        val line = r.stdout.lines().firstOrNull {
            it.startsWith("127.0.0.1:") && it.contains("\tdevice")
        }
        return line?.substringBefore("\t")?.substringAfter(":")?.toIntOrNull()
    }

    // ── 通知 ──────────────────────────────────────────────────────────────────

    private fun ensureNotifChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(NOTIF_CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    NOTIF_CHANNEL_ID,
                    "CableBee 配对本机",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "无线调试配对本机提示"
                    setSound(null, null)
                }
                nm.createNotificationChannel(ch)
            }
        }
    }

    /**
     * 发配对通知。
     * discoveredPairPort <= 0 → 单框输入「端口:配对码」格式，如 39987:123456
     * discoveredPairPort >  0 → 单框只输配对码（端口已由 mDNS 自动获取）
     */
    private fun showPairCodeNotification(port: Int = -1) {
        val nm = getSystemService(NotificationManager::class.java)
        val portKnown = discoveredPairPort > 0

        val replyIntent = Intent(ACTION_PAIR_CODE).apply {
            setPackage(packageName)
            putExtra(EXTRA_PORT, if (portKnown) discoveredPairPort else -1)
        }
        val replyPi = PendingIntent.getBroadcast(
            this, NOTIF_REQ_REPLY, replyIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            else
                PendingIntent.FLAG_UPDATE_CURRENT
        )

        // 始终单个输入框，避免 ColorOS 多 RemoteInput 不工作
        val inputHint = if (portKnown) "配对码（6位数字，如 123456）"
                        else "端口:配对码（如 39987:123456）"
        val singleInput = RemoteInput.Builder(EXTRA_CODE)
            .setLabel(inputHint)
            .build()
        val replyAction = Notification.Action.Builder(null, "输入配对码", replyPi)
            .addRemoteInput(singleInput)
            .build()

        val cancelIntent = Intent(ACTION_CANCEL_PAIR).setPackage(packageName)
        val cancelPi = PendingIntent.getBroadcast(
            this, NOTIF_REQ_CANCEL, cancelIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                PendingIntent.FLAG_IMMUTABLE
            else
                0
        )
        val cancelAction = Notification.Action.Builder(null, "取消", cancelPi).build()

        val (title, bigText) = if (portKnown) {
            "CableBee 配对本机（端口 $discoveredPairPort）" to
            "已自动检测到端口 $discoveredPairPort\n点「输入配对码」，输入无线调试弹窗中的6位配对码即可"
        } else {
            "CableBee 配对本机" to
            "点「输入配对码」，按格式输入：\n端口:配对码\n例如：39987:123456\n（端口和配对码均来自无线调试弹窗）"
        }

        val notif = Notification.Builder(this, NOTIF_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(if (portKnown) "输入6位配对码" else "输入格式：端口:配对码")
            .setStyle(Notification.BigTextStyle().bigText(bigText))
            .addAction(replyAction)
            .addAction(cancelAction)
            .setOngoing(true)
            .build()

        nm.notify(NOTIF_ID, notif)
    }

    /** 将通知更新为「正在配对中…」，无输入框，防止用户重复提交 */
    private fun showPairingInProgressNotification() {
        val nm = getSystemService(NotificationManager::class.java)
        val notif = Notification.Builder(this, NOTIF_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("CableBee 正在配对…")
            .setContentText("正在执行 adb pair，请稍候")
            .setOngoing(true)
            .build()
        nm.notify(NOTIF_ID, notif)
    }

    /** 配对成功后显示「配对成功」通知，用户返回 App 后自动关闭 */
    private fun showPairSuccessNotification() {
        val nm = getSystemService(NotificationManager::class.java)
        val notif = Notification.Builder(this, NOTIF_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("CableBee 配对成功 ✓")
            .setContentText("已成功配对本机，返回 App 即可使用")
            .setOngoing(false)
            .setAutoCancel(true)
            .build()
        nm.notify(NOTIF_ID, notif)
    }

    private fun dismissNotification() {
        getSystemService(NotificationManager::class.java).cancel(NOTIF_ID)
    }

    // ── BroadcastReceiver（接收通知栏 RemoteInput 结果）─────────────────────

    private val pairCodeReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(ctx: android.content.Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_PAIR_CODE -> {
                    val portFromIntent = intent.getIntExtra(EXTRA_PORT, -1)
                    val results = RemoteInput.getResultsFromIntent(intent)
                    val raw = results?.getCharSequence(EXTRA_CODE)?.toString()?.trim() ?: ""

                    // 解析输入：mDNS 已知端口时只输配对码；否则格式为「端口:配对码」
                    val port: Int
                    val code: String
                    if (portFromIntent > 0) {
                        // mDNS 发现了端口，直接用，raw 就是配对码
                        port = portFromIntent
                        code = raw
                    } else if (raw.contains(":")) {
                        // 用户输入了「端口:配对码」格式
                        val parts = raw.split(":", limit = 2)
                        port = parts[0].trim().toIntOrNull() ?: -1
                        code = parts[1].trim()
                    } else {
                        // 兜底：也尝试用 discoveredPairPort
                        port = if (discoveredPairPort > 0) discoveredPairPort else -1
                        code = raw
                    }

                    Log.i(TAG, "selfPair: got code=$code port=$port from notification (raw=$raw)")
                    if (port > 0 && code.isNotEmpty()) {
                        // 立即把通知更新为「正在配对中…」，防止用户重复提交，也明确告知进度
                        showPairingInProgressNotification()
                        executeSelfPair(port, code)
                    } else {
                        Log.w(TAG, "selfPair: invalid port=$port or empty code, ignoring")
                        // 输入格式有误，且流程仍在进行时才重置通知
                        if (selfPairingActive) ui { showPairCodeNotification() }
                    }
                }
                ACTION_CANCEL_PAIR -> {
                    Log.i(TAG, "selfPair: cancelled by user")
                    stopSelfPairDiscovery()
                    dismissNotification()
                }
            }
        }
    }

    // ── Fastboot USB 权限请求 ─────────────────────────────────────────────────

    private val ACTION_USB_PERMISSION = "com.cablebee.USB_PERMISSION"

    // 挂起的 fastboot MethodChannel result，等用户授权后继续
    private var pendingFastbootResult: MethodChannel.Result? = null
    private var pendingFastbootArgs:   List<String>? = null

    private val usbPermissionReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(ctx: android.content.Context?, intent: Intent?) {
            if (intent?.action != ACTION_USB_PERMISSION) return
            val device: UsbDevice? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                else
                    @Suppress("DEPRECATION") intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)

            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            Log.i(TAG, "USB permission: granted=$granted device=${device?.deviceName}")

            val result = pendingFastbootResult
            val args   = pendingFastbootArgs
            pendingFastbootResult = null
            pendingFastbootArgs   = null

            if (granted && device != null && result != null && args != null) {
                scope.launch { runFastbootWithDevice(device, args, result) }
            } else {
                result?.error("USB_PERMISSION_DENIED", "用户拒绝了 USB 权限", null)
            }
        }
    }

    /**
     * 找到处于 fastboot 模式的 USB 设备。
     * Fastboot 接口特征：class=0xFF, subclass=0x42, protocol=0x03
     * 部分 OEM（如小米）：class=0xFF, subclass=0x00, protocol=0x00
     */
    private fun findFastbootDevice(): UsbDevice? {
        val usbManager = getSystemService(USB_SERVICE) as UsbManager
        for (device in usbManager.deviceList.values) {
            for (i in 0 until device.interfaceCount) {
                val iface = device.getInterface(i)
                val cls  = iface.interfaceClass
                val sub  = iface.interfaceSubclass
                val prot = iface.interfaceProtocol
                Log.d(TAG, "USB ${device.deviceName} iface[$i] class=$cls sub=$sub prot=$prot")
                if (cls == 0xFF && ((sub == 0x42 && prot == 0x03) || (sub == 0x00 && prot == 0x00))) {
                    Log.i(TAG, "fastboot device found: ${device.deviceName}")
                    return device
                }
            }
        }
        return null
    }

    /**
     * 请求 USB 权限，权限结果通过 [usbPermissionReceiver] 异步回调。
     * 若已有权限则直接执行。
     */
    private fun requestFastbootPermissionAndRun(
        device: UsbDevice,
        args:   List<String>,
        result: MethodChannel.Result,
    ) {
        val usbManager = getSystemService(USB_SERVICE) as UsbManager
        if (usbManager.hasPermission(device)) {
            scope.launch { runFastbootWithDevice(device, args, result) }
            return
        }
        // 存起来，等广播回调
        pendingFastbootResult = result
        pendingFastbootArgs   = args
        val pi = PendingIntent.getBroadcast(
            this, 0,
            Intent(ACTION_USB_PERMISSION).setPackage(packageName),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            else
                PendingIntent.FLAG_UPDATE_CURRENT
        )
        usbManager.requestPermission(device, pi)
    }

    /**
     * 已取得 USB 权限后直接执行 fastboot。
     * 不使用 -d <fd>（Android 版 fastboot 不支持该选项）。
     * App 进程已持有 USB 权限，子进程通过继承的 /dev/bus/usb 访问权限找到设备。
     * 同时通过环境变量 ANDROID_SERIAL 锁定目标设备，避免多设备歧义。
     */
    private fun runFastbootWithDevice(
        device: UsbDevice,
        args:   List<String>,
        result: MethodChannel.Result,
    ) {
        val usbManager = getSystemService(USB_SERVICE) as UsbManager
        // 必须先 openDevice，保持连接打开，让子进程能访问该设备节点
        val connection = usbManager.openDevice(device)
        if (connection == null) {
            ui { result.error("USB_OPEN_FAILED", "无法打开 USB 设备", null) }
            return
        }

        try {
            val cmd = mutableListOf(fastbootBin.absolutePath) + args
            Log.d(TAG, "fastboot exec: ${cmd.joinToString(" ")}")

            val proc = ProcessBuilder(cmd).apply {
                environment()["HOME"]            = filesDir.absolutePath
                environment()["TMPDIR"]          = cacheDir.absolutePath
                // 锁定设备序列号（fastboot 通过 USB 序列号匹配）
                val serial = runCatching { device.serialNumber }.getOrNull()
                if (!serial.isNullOrEmpty()) {
                    environment()["ANDROID_SERIAL"] = serial
                }
            }.redirectErrorStream(true).start()

            val outBuf = StringBuilder()
            val reader = Thread {
                try { outBuf.append(proc.inputStream.bufferedReader().readText()) }
                catch (_: Exception) {}
            }.also { it.isDaemon = true; it.start() }

            val exited = proc.waitFor(30, TimeUnit.SECONDS)
            if (!exited) proc.destroyForcibly()
            reader.join(2_000)

            val output   = outBuf.toString().trim()
            val exitCode = if (exited) runCatching { proc.exitValue() }.getOrDefault(1) else 1
            Log.d(TAG, "fastboot exit=$exitCode output=${output.take(200)}")

            ui { result.success(mapOf("exitCode" to exitCode, "output" to output)) }
        } catch (e: Exception) {
            Log.e(TAG, "fastboot error: ${e.message}")
            ui { result.error("FASTBOOT_ERROR", e.message, null) }
        } finally {
            connection.close()
        }
    }

    // ── Flutter Engine 配置 ──────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        initBinaries()

        // 注册 BroadcastReceiver
        val filter = android.content.IntentFilter().apply {
            addAction(ACTION_PAIR_CODE)
            addAction(ACTION_CANCEL_PAIR)
            addAction(ACTION_USB_PERMISSION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pairCodeReceiver, filter, RECEIVER_NOT_EXPORTED)
            registerReceiver(usbPermissionReceiver, android.content.IntentFilter(ACTION_USB_PERMISSION), RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(pairCodeReceiver, filter)
            registerReceiver(usbPermissionReceiver, android.content.IntentFilter(ACTION_USB_PERMISSION))
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

        // ── FASTBOOT ──────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FASTBOOT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // run(args: List<String>) → {exitCode: Int, output: String}
                    // 自动查找 fastboot 设备，请求 USB 权限后执行
                    "run" -> {
                        val args = call.argument<List<String>>("args")
                            ?: return@setMethodCallHandler result.error("BAD_ARG", "args required", null)

                        if (!fastbootBin.exists()) {
                            result.error("BINARY_MISSING", "fastboot 二进制不存在: ${fastbootBin.absolutePath}", null)
                            return@setMethodCallHandler
                        }

                        val device = findFastbootDevice()
                        if (device == null) {
                            // 没找到设备时，直接跑不带 -d 的命令（fallback，输出 fastboot devices 等）
                            scope.launch {
                                try {
                                    val cmd = mutableListOf(fastbootBin.absolutePath) + args
                                    Log.d(TAG, "fastboot (no device) exec: ${cmd.joinToString(" ")}")
                                    val proc = ProcessBuilder(cmd).apply {
                                        environment()["HOME"]   = filesDir.absolutePath
                                        environment()["TMPDIR"] = cacheDir.absolutePath
                                        redirectErrorStream(true)
                                    }.start()
                                    val out = proc.inputStream.bufferedReader().readText().trim()
                                    val exited = proc.waitFor(10, TimeUnit.SECONDS)
                                    if (!exited) proc.destroyForcibly()
                                    val exit = if (exited) runCatching { proc.exitValue() }.getOrDefault(1) else 1
                                    ui { result.success(mapOf("exitCode" to exit, "output" to out)) }
                                } catch (e: Exception) {
                                    ui { result.error("FASTBOOT_ERROR", e.message, null) }
                                }
                            }
                            return@setMethodCallHandler
                        }

                        requestFastbootPermissionAndRun(device, args, result)
                    }

                    // getDevices() → {connected: Bool, serial: String?}
                    "getDevices" -> {
                        if (!fastbootBin.exists()) {
                            result.success(mapOf("connected" to false, "serial" to null))
                            return@setMethodCallHandler
                        }
                        val device = findFastbootDevice()
                        if (device == null) {
                            result.success(mapOf("connected" to false, "serial" to null))
                            return@setMethodCallHandler
                        }
                        val usbManager = getSystemService(USB_SERVICE) as UsbManager
                        if (!usbManager.hasPermission(device)) {
                            // 有设备但没有权限，先报告已找到设备（连接中），让 UI 弹权限
                            result.success(mapOf("connected" to false, "serial" to null, "needsPermission" to true))
                            return@setMethodCallHandler
                        }
                        // 已有权限：用 fastboot devices 确认
                        scope.launch {
                            try {
                                val connection = usbManager.openDevice(device)
                                if (connection == null) {
                                    ui { result.success(mapOf("connected" to false, "serial" to null)) }
                                    return@launch
                                }
                                val cmd = mutableListOf(fastbootBin.absolutePath, "devices")
                                val proc = ProcessBuilder(cmd).apply {
                                    environment()["HOME"]   = filesDir.absolutePath
                                    environment()["TMPDIR"] = cacheDir.absolutePath
                                    redirectErrorStream(true)
                                }.start()
                                val out = proc.inputStream.bufferedReader().readText().trim()
                                proc.waitFor(8, TimeUnit.SECONDS)
                                connection.close()
                                Log.d(TAG, "fastboot devices output: $out")
                                val connected = out.isNotEmpty() && out.contains("\t")
                                val serial = if (connected) out.lines()
                                    .firstOrNull { it.contains("\t") }
                                    ?.substringBefore("\t")?.trim() else null
                                ui { result.success(mapOf("connected" to connected, "serial" to serial)) }
                            } catch (e: Exception) {
                                ui { result.success(mapOf("connected" to false, "serial" to null)) }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // ── ADB ───────────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ADB_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "getNativeLibraryDir" ->
                        result.success(applicationInfo.nativeLibraryDir)

                    // ── 新增：启动配对本机流程 ─────────────────────────────
                    "startSelfPair" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            startSelfPairDiscovery()
                            result.success(null)
                        } else {
                            result.error("UNSUPPORTED", "需要 Android 11 及以上", null)
                        }
                    }

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

                    // forward(serial, local, remote) → String
                    "forward" -> {
                        val serial = call.argument<String>("serial") ?: return@setMethodCallHandler result.error("BAD_ARG","serial required",null)
                        val local  = call.argument<String>("local")  ?: return@setMethodCallHandler result.error("BAD_ARG","local required",null)
                        val remote = call.argument<String>("remote") ?: return@setMethodCallHandler result.error("BAD_ARG","remote required",null)
                        scope.launch {
                            adb("-s", serial, "forward", "--remove", local, timeoutMs = 5_000)
                            val r = adb("-s", serial, "forward", local, remote, timeoutMs = 5_000)
                            ui {
                                if (r.exit == 0) result.success(r.output)
                                else result.error("FORWARD_FAILED", r.output, null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // ── SHELL STREAM ──────────────────────────────────────────────────
        // 逐行实时推送 adb shell 输出，供 Flutter 流式消费
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SHELL_STREAM_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                private var streamJob: kotlinx.coroutines.Job? = null

                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    if (sink == null) return
                    val args   = arguments as? Map<*, *> ?: return
                    val serial  = args["serial"]  as? String ?: return
                    val command = args["command"] as? String ?: return
                    val timeout = (args["timeoutMs"] as? Int)?.toLong() ?: 120_000L

                    streamJob = scope.launch {
                        try {
                            val cmd = mutableListOf(adbBin.absolutePath, "-s", serial, "shell", command)
                            val proc = ProcessBuilder(cmd).apply {
                                environment()["HOME"]                    = filesDir.absolutePath
                                environment()["TMPDIR"]                  = cacheDir.absolutePath
                                environment()["ANDROID_ADB_SERVER_PORT"] = "15037"
                            }.redirectErrorStream(false).start()

                            // 逐行读取 stdout，实时推送到 Flutter
                            val reader = proc.inputStream.bufferedReader()
                            val deadline = System.currentTimeMillis() + timeout
                            while (System.currentTimeMillis() < deadline) {
                                val line = reader.readLine() ?: break  // EOF
                                ui { sink.success(line) }
                            }
                            proc.destroyForcibly()
                            ui { sink.endOfStream() }
                        } catch (e: Exception) {
                            ui { sink.error("SHELL_STREAM_ERROR", e.message, null) }
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    streamJob?.cancel()
                    streamJob = null
                }
            })

        // ── SELF PAIR EVENTS ──────────────────────────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SELF_PAIR_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(a: Any?, s: EventChannel.EventSink?) { selfPairEventSink = s }
                override fun onCancel(a: Any?) { selfPairEventSink = null }
            })

        // ── LOCAL APPS ────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCAL_APPS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

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

        // ── SCRCPY ────────────────────────────────────────────────────────
        scrcpyChannel = ScrcpyChannel(
            textureRegistry = flutterEngine.renderer,
            scope           = scope,
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCRCPY_METHOD)
            .setMethodCallHandler(scrcpyChannel!!.methodHandler)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SCRCPY_EVENTS)
            .setStreamHandler(scrcpyChannel!!.streamHandler)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        when (intent.action) {
            UsbManager.ACTION_USB_DEVICE_ATTACHED -> usbEventSink?.success(mapOf("event" to "attached"))
            UsbManager.ACTION_USB_DEVICE_DETACHED -> usbEventSink?.success(mapOf("event" to "detached"))
        }
    }

    override fun onResume() {
        super.onResume()
        intent?.let { onNewIntent(it) }
        // 配对成功后用户返回 App，关闭成功通知
        if (pairSucceeded) {
            pairSucceeded = false
            dismissNotification()
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(pairCodeReceiver) }
        runCatching { unregisterReceiver(usbPermissionReceiver) }
        stopSelfPairDiscovery()
        dismissNotification()
        scope.cancel()
        super.onDestroy()
    }
}
