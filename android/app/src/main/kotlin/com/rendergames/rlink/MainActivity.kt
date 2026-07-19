package com.rendergames.rlink

import android.app.DownloadManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Environment
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import android.os.Build
import android.os.ParcelUuid
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {

    override fun getCachedEngineId(): String = RlinkApplication.ENGINE_ID

    companion object {
        const val METHOD_CHANNEL = "com.rendergames.rlink/ble"
        const val EVENT_CHANNEL  = "com.rendergames.rlink/ble_events"
        const val PROXIMITY_CHANNEL = "com.rendergames.rlink/proximity"
        const val NOTIFICATION_CHANNEL_ID = "rlink_messages"
        private const val APP_ICON_CHANNEL_ID = "rlink_app_icon"
        private const val APP_ICON_NOTIFICATION_ID = 91001
        val SERVICE_UUID: UUID = UUID.fromString("12345678-1234-5678-1234-56789abcdef0")
        val TX_CHAR_UUID: UUID = UUID.fromString("12345678-1234-5678-1234-56789abcdef1")
        val CCCD_UUID:    UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var gattServer: BluetoothGattServer? = null
    private var eventSink: EventChannel.EventSink? = null
    private val subscribedDevices = mutableSetOf<BluetoothDevice>()

    // Per-device write buffers for reassembling framed BLE packets
    // (same protocol as iOS: 2-byte big-endian length header + payload)
    private val writeBuffers = mutableMapOf<String, ByteArray>()

    // Флаг — предотвращаем дублирование
    private var isAdvertising = false
    private var isGattServerRunning = false

    // Отслеживаем foreground/background для уведомлений
    private var isAppInForeground = false
    private var proximityChannel: MethodChannel? = null
    private var sensorManager: SensorManager? = null
    private var proximitySensor: Sensor? = null
    private var proximityWakeLock: PowerManager.WakeLock? = null
    private var proximityMonitoring = false
    private var lastProximityNear: Boolean? = null
    private val proximityListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val sensor = proximitySensor ?: return
            val near = event.values.isNotEmpty() && event.values[0] < sensor.maximumRange
            if (lastProximityNear == near) return
            lastProximityNear = near
            proximityChannel?.invokeMethod("onProximityChanged", near)
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    override fun onResume() {
        super.onResume()
        isAppInForeground = true
        try {
            startService(
                Intent(this, RlinkForegroundService::class.java)
                    .setAction(RlinkForegroundService.ACTION_STOP)
            )
        } catch (_: Exception) { }
    }

    override fun onPause() {
        super.onPause()
        isAppInForeground = false
        try {
            ContextCompat.startForegroundService(
                this,
                Intent(this, RlinkForegroundService::class.java)
                    .setAction(RlinkForegroundService.ACTION_START)
            )
        } catch (e: Exception) {
            Log.w("Rlink", "foreground service: ${e.message}")
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
        ensureAppIconNotificationChannel()
    }

    override fun onDestroy() {
        stopProximityMonitoring()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Сообщения Rlink",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Уведомления о новых сообщениях"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun showMessageNotification(title: String = "Rlink", body: String = "Новое сообщение", sound: Boolean = true, vibration: Boolean = true) {
        if (isAppInForeground) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Recreate channel with correct sound/vibration settings
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val importance = if (sound) NotificationManager.IMPORTANCE_DEFAULT else NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(NOTIFICATION_CHANNEL_ID, "Сообщения Rlink", importance).apply {
                description = "Уведомления о новых сообщениях"
                enableVibration(vibration)
                if (!sound) setSound(null, null)
            }
            manager.createNotificationChannel(channel)
        }

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)

        if (!sound) builder.setSound(null)
        if (!vibration) builder.setVibrate(null)

        manager.notify(System.currentTimeMillis().toInt(), builder.build())
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.rendergames.rlink/app_icon")
            .setMethodCallHandler { call, result ->
                if (call.method == "setIcon") {
                    try {
                        val variant = call.argument<String>("variant") ?: "default"
                        setAppIcon(variant)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("ICON", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // Audio → WAV (for on-device Whisper): decode the recorded m4a/aac to a
        // PCM16 WAV; the native whisper bridge down-mixes + resamples to 16 kHz.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.rendergames.rlink/audio")
            .setMethodCallHandler { call, result ->
                if (call.method == "toWav") {
                    val src = call.argument<String>("src")
                    val dst = call.argument<String>("dst")
                    if (src == null || dst == null) {
                        result.error("ARG", "missing src/dst", null)
                    } else {
                        Thread {
                            try {
                                decodeAudioToWav(src, dst)
                                runOnUiThread { result.success(dst) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("DECODE", e.message, null) }
                            }
                        }.start()
                    }
                } else {
                    result.notImplemented()
                }
            }

        proximityChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PROXIMITY_CHANNEL
        )
        proximityChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startProximityMonitoring()
                    result.success(null)
                }
                "stop" -> {
                    stopProximityMonitoring()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startAdvertising" -> {
                        if (!isGattServerRunning) startGattServer()
                        if (!isAdvertising) startAdvertising()
                        result.success(null)
                    }
                    "stopAdvertising" -> {
                        stopAdvertising()
                        result.success(null)
                    }
                    "sendPacket" -> {
                        val bytes = call.argument<ByteArray>("data")
                        if (bytes != null) notifySubscribers(bytes)
                        result.success(null)
                    }
                    "showNotification" -> {
                        val title = call.argument<String>("title") ?: "Rlink"
                        val body = call.argument<String>("body") ?: "Новое сообщение"
                        val sound = call.argument<Boolean>("sound") ?: true
                        val vibration = call.argument<Boolean>("vibration") ?: true
                        showMessageNotification(title, body, sound, vibration)
                        result.success(null)
                    }
                    "clearApplicationBadge" -> {
                        // iOS сбрасывает число на иконке нативно. На Android счётчик на иконке
                        // обычно привязан к активным уведомлениям — не делаем cancelAll при resume,
                        // чтобы не очищать центр уведомлений.
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) { eventSink = sink }
                override fun onCancel(args: Any?) { eventSink = null }
            })

        // Native square video cropping
        VideoCropPlugin.register(flutterEngine.dartExecutor.binaryMessenger)

        // In-app updater: download an APK in the background (system DownloadManager,
        // survives minimizing/killing the app) and install it via the system installer.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
                "com.rendergames.rlink/updates")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("ARG", "missing path", null)
                        } else {
                            try {
                                installApk(path)
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("INSTALL", e.message, null)
                            }
                        }
                    }
                    "downloadApk" -> {
                        val url = call.argument<String>("url")
                        val fileName = call.argument<String>("fileName")
                        if (url.isNullOrEmpty() || fileName.isNullOrEmpty()) {
                            result.error("ARG", "missing url/fileName", null)
                        } else {
                            try {
                                result.success(enqueueApkDownload(url, fileName))
                            } catch (e: Exception) {
                                result.error("DOWNLOAD", e.message, null)
                            }
                        }
                    }
                    "downloadStatus" -> {
                        val id = (call.argument<Number>("id"))?.toLong()
                        if (id == null) {
                            result.error("ARG", "missing id", null)
                        } else {
                            try {
                                result.success(queryDownload(id))
                            } catch (e: Exception) {
                                result.error("STATUS", e.message, null)
                            }
                        }
                    }
                    "cancelDownload" -> {
                        val id = (call.argument<Number>("id"))?.toLong()
                        if (id != null) {
                            try {
                                (getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager)
                                    .remove(id)
                            } catch (_: Exception) { }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Ставит APK в очередь системного DownloadManager. Загрузка идёт вне
    /// процесса приложения — продолжается, даже если приложение свёрнуто или
    /// выгружено системой; в шторке видно прогресс. Возвращает downloadId.
    private fun enqueueApkDownload(url: String, fileName: String): Long {
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        // Пишем в приватную external-files-папку (без разрешений на storage),
        // её же отдаёт FileProvider установщику. Старый файл удаляем.
        val destFile = File(
            getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), fileName)
        if (destFile.exists()) destFile.delete()
        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle("Rlink")
            setDescription("Загрузка обновления…")
            setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            setDestinationInExternalFilesDir(
                this@MainActivity, Environment.DIRECTORY_DOWNLOADS, fileName)
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
            addRequestHeader("Accept", "application/octet-stream")
        }
        return dm.enqueue(request)
    }

    /// Состояние фоновой загрузки: status(pending|running|paused|successful|
    /// failed|unknown), сколько байт скачано/всего, локальный путь по готовности.
    private fun queryDownload(id: Long): Map<String, Any?> {
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val cursor = dm.query(DownloadManager.Query().setFilterById(id))
            ?: return mapOf("status" to "unknown")
        return cursor.use { c ->
            if (!c.moveToFirst()) {
                mapOf("status" to "unknown")
            } else {
                val status = c.getInt(
                    c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                val downloaded = c.getLong(
                    c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                val total = c.getLong(
                    c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                val reason = c.getInt(
                    c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                val localUri = c.getString(
                    c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))
                val statusStr = when (status) {
                    DownloadManager.STATUS_PENDING -> "pending"
                    DownloadManager.STATUS_RUNNING -> "running"
                    DownloadManager.STATUS_PAUSED -> "paused"
                    DownloadManager.STATUS_SUCCESSFUL -> "successful"
                    DownloadManager.STATUS_FAILED -> "failed"
                    else -> "unknown"
                }
                val path = if (localUri != null) Uri.parse(localUri).path else null
                mapOf(
                    "status" to statusStr,
                    "downloaded" to downloaded,
                    "total" to total,
                    "reason" to reason,
                    "path" to path,
                )
            }
        }
    }

    /// Открывает системный установщик для скачанного APK (обновление).
    private fun installApk(path: String) {
        val file = File(path)
        val uri = FileProvider.getUriForFile(
            this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_GRANT_READ_URI_PERMISSION
        }
        startActivity(intent)
    }

    private fun startProximityMonitoring() {
        if (proximityMonitoring) return
        val sm = getSystemService(Context.SENSOR_SERVICE) as? SensorManager ?: return
        val sensor = sm.getDefaultSensor(Sensor.TYPE_PROXIMITY) ?: return
        sensorManager = sm
        proximitySensor = sensor
        lastProximityNear = null
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            proximityWakeLock = pm.newWakeLock(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                "Rlink:CallProximity"
            )
            proximityWakeLock?.acquire()
        } catch (e: Exception) {
            Log.w("Rlink", "proximity wakelock: ${e.message}")
        }
        sm.registerListener(proximityListener, sensor, SensorManager.SENSOR_DELAY_NORMAL)
        proximityMonitoring = true
    }

    private fun stopProximityMonitoring() {
        if (!proximityMonitoring && proximityWakeLock == null) return
        try {
            sensorManager?.unregisterListener(proximityListener)
        } catch (_: Exception) { }
        try {
            val wl = proximityWakeLock
            if (wl?.isHeld == true) wl.release()
        } catch (_: Exception) { }
        proximityWakeLock = null
        proximityMonitoring = false
        proximitySensor = null
        lastProximityNear = false
        proximityChannel?.invokeMethod("onProximityChanged", false)
    }

    private fun ensureAppIconNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        val ch = NotificationChannel(
            APP_ICON_CHANNEL_ID,
            "Иконка приложения",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Уведомление после смены ярлыка на рабочем столе"
        }
        mgr.createNotificationChannel(ch)
    }

    private fun showAppIconChangedNotification(variant: String) {
        ensureAppIconNotificationChannel()
        val variantLabel = when (variant) {
            "mono" -> "моно"
            "ai" -> "ИИ Rlink"
            else -> "классическая"
        }
        val bigText =
            "Установлена иконка: $variantLabel. Если лаунчер кэширует значок, обновление может занять несколько секунд."

        val openApp = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val contentPending = PendingIntent.getActivity(this, 1, openApp, pendingFlags)

        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = NotificationCompat.Builder(this, APP_ICON_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Иконка Rlink изменена")
            .setContentText("Вариант: $variantLabel")
            .setStyle(NotificationCompat.BigTextStyle().bigText(bigText))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(contentPending)
            .build()

        mgr.notify(APP_ICON_NOTIFICATION_ID, notification)
    }

    private fun setAppIcon(variant: String) {
        val pm = packageManager
        val pkg = packageName
        val def = ComponentName(pkg, "$pkg.LauncherIconDefault")
        val mono = ComponentName(pkg, "$pkg.LauncherIconMono")
        val ai = ComponentName(pkg, "$pkg.LauncherIconAi")
        val off = PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        val on = PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        val f = PackageManager.DONT_KILL_APP
        when (variant) {
            "mono" -> {
                pm.setComponentEnabledSetting(def, off, f)
                pm.setComponentEnabledSetting(ai, off, f)
                pm.setComponentEnabledSetting(mono, on, f)
            }
            "ai" -> {
                pm.setComponentEnabledSetting(def, off, f)
                pm.setComponentEnabledSetting(mono, off, f)
                pm.setComponentEnabledSetting(ai, on, f)
            }
            else -> {
                pm.setComponentEnabledSetting(mono, off, f)
                pm.setComponentEnabledSetting(ai, off, f)
                pm.setComponentEnabledSetting(def, on, f)
            }
        }
        showAppIconChangedNotification(variant)
    }

    private fun startGattServer() {
        // Закрываем старый если есть
        gattServer?.close()
        subscribedDevices.clear()

        val txChar = BluetoothGattCharacteristic(
            TX_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY or
            BluetoothGattCharacteristic.PROPERTY_WRITE or
            BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_READ or
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        txChar.addDescriptor(BluetoothGattDescriptor(
            CCCD_UUID,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        ))
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(txChar)

        gattServer = bluetoothManager?.openGattServer(this, gattServerCallback)
        gattServer?.addService(service)
        isGattServerRunning = true
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                subscribedDevices.remove(device)
                writeBuffers.remove(device.address)
                runOnUiThread {
                    eventSink?.success(mapOf("type" to "central_unsubscribed", "device" to device.address))
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray
        ) {
            if (characteristic.uuid == TX_CHAR_UUID) {
                val deviceId = device.address
                var buf = writeBuffers[deviceId] ?: ByteArray(0)
                buf = buf + value

                // Extract all complete length-prefixed packets from the buffer
                while (buf.size >= 2) {
                    val length = ((buf[0].toInt() and 0xFF) shl 8) or (buf[1].toInt() and 0xFF)
                    if (length == 0 || length > 2000) {
                        // Corrupt frame — clear buffer
                        buf = ByteArray(0)
                        break
                    }
                    if (buf.size < length + 2) break // incomplete packet, wait for more data
                    val packet = buf.copyOfRange(2, length + 2)
                    buf = if (buf.size > length + 2) buf.copyOfRange(length + 2, buf.size) else ByteArray(0)

                    // Send complete reassembled packet to Flutter with device ID.
                    // Notification is handled on the Dart side after gossip dedup —
                    // do NOT call showMessageNotification() here (it would fire
                    // once per BLE packet, causing duplicate notifications).
                    runOnUiThread {
                        eventSink?.success(mapOf("type" to "data", "device" to deviceId, "data" to packet))
                    }
                }
                writeBuffers[deviceId] = buf
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray
        ) {
            if (descriptor.uuid == CCCD_UUID) {
                if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                    subscribedDevices.add(device)
                    runOnUiThread {
                        eventSink?.success(mapOf("type" to "central_subscribed", "device" to device.address))
                    }
                } else {
                    subscribedDevices.remove(device)
                    writeBuffers.remove(device.address)
                    runOnUiThread {
                        eventSink?.success(mapOf("type" to "central_unsubscribed", "device" to device.address))
                    }
                }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }
    }

    private fun notifySubscribers(data: ByteArray) {
        val service = gattServer?.getService(SERVICE_UUID) ?: return
        val char    = service.getCharacteristic(TX_CHAR_UUID) ?: return

        // Prepend 2-byte big-endian length header (same protocol as iOS)
        val length = data.size
        val framed = ByteArray(2 + length)
        framed[0] = ((length shr 8) and 0xFF).toByte()
        framed[1] = (length and 0xFF).toByte()
        System.arraycopy(data, 0, framed, 2, length)

        // Send full framed packet in one notification per device.
        // flutter_blue_plus negotiates MTU 512, so packets up to 509 bytes fit.
        // The flutter_blue_plus _writeChar (GATT client) path provides reliable
        // chunked delivery as backup for any packets that exceed the MTU.
        // NOTE: Do NOT chunk in a loop here — setting char.value multiple times
        // before the BLE stack sends previous notifications causes data corruption.
        char.value = framed
        subscribedDevices.toList().forEach { device ->
            try {
                gattServer?.notifyCharacteristicChanged(device, char, false)
            } catch (e: Exception) {
                subscribedDevices.remove(device)
            }
        }
    }

    private fun startAdvertising() {
        advertiser = bluetoothAdapter?.bluetoothLeAdvertiser ?: return

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        advertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    private fun stopAdvertising() {
        try { advertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
        try { gattServer?.close() } catch (_: Exception) {}
        isAdvertising = false
        isGattServerRunning = false
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            isAdvertising = true
            runOnUiThread { eventSink?.success(mapOf("type" to "advertising_started")) }
        }
        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            // Код 3 = уже запущен — не считаем ошибкой
            if (errorCode != 3) {
                runOnUiThread {
                    eventSink?.error("ADV_FAILED", "Advertising failed: $errorCode", null)
                }
            } else {
                isAdvertising = true // уже работает
                runOnUiThread { eventSink?.success(mapOf("type" to "advertising_started")) }
            }
        }
    }

    // ── Audio decode (m4a/aac → PCM16 WAV) for on-device Whisper ────────────
    private fun decodeAudioToWav(srcPath: String, dstPath: String) {
        val extractor = MediaExtractor()
        extractor.setDataSource(srcPath)
        var trackIndex = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                trackIndex = i; format = f; break
            }
        }
        if (trackIndex < 0 || format == null) throw IllegalStateException("no audio track")
        extractor.selectTrack(trackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()
        val pcm = ByteArrayOutputStream()
        val info = MediaCodec.BufferInfo()
        var sawInputEOS = false
        var sawOutputEOS = false
        while (!sawOutputEOS) {
            if (!sawInputEOS) {
                val inIdx = codec.dequeueInputBuffer(10000)
                if (inIdx >= 0) {
                    val ib = codec.getInputBuffer(inIdx)!!
                    val sz = extractor.readSampleData(ib, 0)
                    if (sz < 0) {
                        codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        sawInputEOS = true
                    } else {
                        codec.queueInputBuffer(inIdx, 0, sz, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            val outIdx = codec.dequeueOutputBuffer(info, 10000)
            if (outIdx >= 0) {
                val ob = codec.getOutputBuffer(outIdx)!!
                val chunk = ByteArray(info.size)
                ob.get(chunk)
                ob.clear()
                if (info.size > 0) pcm.write(chunk)
                codec.releaseOutputBuffer(outIdx, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) sawOutputEOS = true
            }
        }
        codec.stop(); codec.release(); extractor.release()
        writeWav(dstPath, pcm.toByteArray(), sampleRate, channels)
    }

    private fun writeWav(path: String, pcm: ByteArray, sampleRate: Int, channels: Int) {
        val byteRate = sampleRate * channels * 2
        val dataLen = pcm.size
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray())
        header.putInt(36 + dataLen)
        header.put("WAVE".toByteArray())
        header.put("fmt ".toByteArray())
        header.putInt(16)
        header.putShort(1)                       // PCM
        header.putShort(channels.toShort())
        header.putInt(sampleRate)
        header.putInt(byteRate)
        header.putShort((channels * 2).toShort()) // block align
        header.putShort(16)                       // bits
        header.put("data".toByteArray())
        header.putInt(dataLen)
        FileOutputStream(File(path)).use { out ->
            out.write(header.array())
            out.write(pcm)
        }
    }
}
