package com.horken7.meetingnotes

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.horken7.meetingnotes.core.Catalog
import com.horken7.meetingnotes.core.Meta
import com.horken7.meetingnotes.core.Wav
import com.horken7.meetingnotes.core.formatDuration
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingDeque

data class RecordingState(val meetingId: String, val elapsedMs: Long, val level: Float, val silenced: Boolean)
data class ProcessingState(val meetingId: String?, val phase: String, val fraction: Float?)

/** What the service is doing right now, for the screens. */
object Work {
    val recording = MutableStateFlow<RecordingState?>(null)
    val processing = MutableStateFlow<ProcessingState?>(null)
    /** Meetings waiting to be processed, and the one being processed. */
    val queued = MutableStateFlow<Set<String>>(emptySet())
    /** A message for the user when something fails outside a meeting (e.g. a model download). */
    val message = MutableStateFlow<String?>(null)
    @Volatile var current: CancelToken? = null
}

/**
 * The foreground service: records with the screen off (type microphone, with a Stop action in the notification),
 * then transcribes and writes notes (type dataSync), one meeting at a time.
 */
class MeetingService : Service() {
    private sealed interface Job {
        data class Process(val folder: File, val notesOnly: Boolean) : Job
        data class Download(val ids: List<String>) : Job
    }

    private var recorder: Recorder? = null
    private var recordingFolder: File? = null
    private val jobs = LinkedBlockingDeque<Job>()
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "Pipeline").apply { priority = Thread.NORM_PRIORITY } }
    @Volatile private var working = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastNotify = 0L
    private lateinit var settings: Settings

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        settings = Settings(this)
        createChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Every start must call startForeground promptly, whatever the action turns out to be.
        foreground()
        when (intent?.action) {
            ACTION_RECORD -> startRecording()
            ACTION_STOP -> stopRecording()
            ACTION_PROCESS -> intent.getStringExtra(EXTRA_FOLDER)?.let {
                enqueue(Job.Process(Store.folder(it), intent.getBooleanExtra(EXTRA_NOTES_ONLY, false)))
            }
            ACTION_DOWNLOAD -> enqueue(Job.Download(intent.getStringArrayExtra(EXTRA_IDS)?.toList() ?: emptyList()))
            ACTION_CANCEL -> Work.current?.cancel()
        }
        stopIfIdle()
        return START_NOT_STICKY
    }

    // MARK: Recording

    private fun startRecording() {
        if (recorder != null) return
        val folder = Store.newMeeting(defaultTitle())
        val file = File(folder, Store.AUDIO)
        val r = Recorder(this, file,
            onUpdate = { ms, level, silenced ->
                Work.recording.value = RecordingState(folder.name, ms, level, silenced)
                val now = SystemClock.elapsedRealtime()
                if (now - lastNotify > 1000) { lastNotify = now; notifyForeground() }
            },
            onEnd = { error -> onRecordingEnded(folder, error) })
        try {
            recordingFolder = folder
            recorder = r
            Work.recording.value = RecordingState(folder.name, 0, 0f, false)
            foreground()
            r.start()
            acquireWakeLock()
        } catch (e: Exception) {
            recorder = null
            recordingFolder = null
            Work.recording.value = null
            Store.delete(folder)
            Work.message.value = e.message ?: "The microphone couldn't be opened."
            foreground()
        }
    }

    private fun stopRecording() {
        val r = recorder ?: return
        Thread { r.stop() }.start()   // onRecordingEnded follows on the recorder thread
    }

    private fun onRecordingEnded(folder: File, error: String?) {
        val audio = File(folder, Store.AUDIO)
        Wav.repair(audio)
        val seconds = Wav.durationSeconds(audio)
        recorder = null
        recordingFolder = null
        Work.recording.value = null
        if (seconds < 1.0) {
            Store.delete(folder)   // a tap on Start then Stop: nothing to keep
            if (error != null) Work.message.value = error
        } else {
            Store.update(folder) { it.copy(status = Meta.TRANSCRIBING, duration = seconds, error = null) }
            if (error != null) Work.message.value = error
            enqueue(Job.Process(folder, false))
        }
        foreground()
        stopIfIdle()
    }

    private fun defaultTitle(): String {
        val t = java.time.LocalTime.now()
        return when (t.hour) {
            in 5..11 -> "Morning meeting"
            in 12..17 -> "Afternoon meeting"
            else -> "Evening meeting"
        }
    }

    // MARK: Processing

    private fun enqueue(job: Job) {
        if (job is Job.Process) {
            val id = job.folder.name
            if (id in Work.queued.value) return
            Work.queued.value = Work.queued.value + id
            Store.update(job.folder) { it.copy(status = if (job.notesOnly && File(job.folder, "transcript.md").exists()) Meta.SUMMARIZING else Meta.TRANSCRIBING, error = null) }
        }
        val start = synchronized(jobs) {
            jobs.add(job)
            (!working).also { working = true }
        }
        if (start) {
            acquireWakeLock()
            foreground()
            worker.execute { drain() }
        }
    }

    private fun drain() {
        while (true) {
            val job = synchronized(jobs) { jobs.poll() ?: null.also { working = false } } ?: break
            val token = CancelToken()
            Work.current = token
            val meetingId = (job as? Job.Process)?.folder?.name
            val pipeline = Pipeline(settings, token) { phase, fraction ->
                Work.processing.value = ProcessingState(meetingId, phase, fraction)
                val now = SystemClock.elapsedRealtime()
                if (now - lastNotify > 1000) { lastNotify = now; notifyForeground() }
            }
            try {
                when (job) {
                    is Job.Process -> {
                        Work.processing.value = ProcessingState(meetingId, "Starting", null)
                        pipeline.run(job.folder, job.notesOnly)
                        notifyFinished(job.folder)
                    }
                    is Job.Download -> {
                        Work.processing.value = ProcessingState(null, "Downloading", 0f)
                        try {
                            pipeline.download(job.ids.mapNotNull { Catalog.byId(it) })
                        } catch (e: CancelledException) {
                        } catch (e: Exception) {
                            Work.message.value = e.message
                        }
                    }
                }
            } catch (e: Throwable) {
                Log.e(TAG, "job failed", e)
            } finally {
                if (meetingId != null) Work.queued.value = Work.queued.value - meetingId
                Work.current = null
                Work.processing.value = null
                Store.changed()
            }
        }
        ContextCompat.getMainExecutor(this).execute {
            foreground()
            stopIfIdle()
        }
    }

    private fun notifyFinished(folder: File) {
        val meeting = Store.load(folder) ?: return
        val text = if (meeting.status == Meta.DONE) "Notes are ready" else (meeting.meta.error ?: "Couldn't finish")
        val n = NotificationCompat.Builder(this, CHANNEL_DONE)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(meeting.title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(openIntent(this, folder.name))
            .setAutoCancel(true)
            .build()
        notificationManager().notify(folder.name.hashCode(), n)
    }

    // MARK: Foreground and notification

    private fun foreground() {
        var type = 0
        if (recorder != null) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if (working || type == 0) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        try {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), type)
        } catch (e: Exception) {
            // E.g. the dataSync type isn't allowed from the background; keep the current type.
            Log.w(TAG, "startForeground($type) failed", e)
            notifyForeground()
        }
    }

    private fun notifyForeground() {
        notificationManager().notify(NOTIFICATION_ID, buildNotification())
    }

    private fun buildNotification(): Notification {
        val b = NotificationCompat.Builder(this, CHANNEL_WORK)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        val rec = Work.recording.value
        val proc = Work.processing.value
        if (recorder != null && rec != null) {
            b.setContentTitle("Recording · ${formatDuration(rec.elapsedMs / 1000.0)}")
            b.setContentText(if (rec.silenced) "Paused: another app (such as a phone call) is using the microphone" else "Tap Stop when the meeting ends")
            b.setContentIntent(openIntent(this, rec.meetingId))
            b.addAction(0, "Stop", PendingIntent.getService(this, 1,
                Intent(this, MeetingService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE))
            b.setCategory(NotificationCompat.CATEGORY_SERVICE)
        } else {
            val title = proc?.meetingId?.let { Store.load(Store.folder(it))?.title }
            b.setContentTitle(proc?.phase ?: "Preparing")
            title?.let { b.setContentText(it) }
            proc?.fraction?.let { b.setProgress(1000, (it * 1000).toInt(), false) } ?: b.setProgress(0, 0, true)
            b.setContentIntent(openIntent(this, proc?.meetingId))
            b.addAction(0, "Stop", PendingIntent.getService(this, 2,
                Intent(this, MeetingService::class.java).setAction(ACTION_CANCEL), PendingIntent.FLAG_IMMUTABLE))
        }
        return b.build()
    }

    private fun stopIfIdle() {
        if (recorder == null && !working && jobs.isEmpty()) {
            releaseWakeLock()
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    @Synchronized private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        // Keeps the CPU running with the screen off while recording or transcribing.
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MeetingNotes:work").apply { acquire(12 * 60 * 60 * 1000L) }
    }

    @Synchronized private fun releaseWakeLock() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15 limits dataSync services to 6 hours a day: stop cleanly instead of being killed.
        Work.current?.cancel()
        jobs.clear()
    }

    override fun onDestroy() {
        recorder?.stop()
        Work.current?.cancel()
        releaseWakeLock()
        worker.shutdown()
        super.onDestroy()
    }

    private fun notificationManager() = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    companion object {
        private const val TAG = "MeetingService"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_WORK = "work"
        private const val CHANNEL_DONE = "done"
        const val ACTION_RECORD = "record"
        const val ACTION_STOP = "stop"
        const val ACTION_PROCESS = "process"
        const val ACTION_DOWNLOAD = "download"
        const val ACTION_CANCEL = "cancel"
        const val EXTRA_FOLDER = "folder"
        const val EXTRA_NOTES_ONLY = "notesOnly"
        const val EXTRA_IDS = "ids"
        const val EXTRA_OPEN = "open"

        private fun send(context: Context, intent: Intent) {
            ContextCompat.startForegroundService(context, intent.setClass(context, MeetingService::class.java))
        }

        fun record(context: Context) = send(context, Intent(ACTION_RECORD))
        fun stop(context: Context) = send(context, Intent(ACTION_STOP))
        fun cancel(context: Context) = send(context, Intent(ACTION_CANCEL))
        fun process(context: Context, meetingId: String, notesOnly: Boolean) =
            send(context, Intent(ACTION_PROCESS).putExtra(EXTRA_FOLDER, meetingId).putExtra(EXTRA_NOTES_ONLY, notesOnly))
        fun download(context: Context, ids: List<String>) =
            send(context, Intent(ACTION_DOWNLOAD).putExtra(EXTRA_IDS, ids.toTypedArray()))

        fun openIntent(context: Context, meetingId: String?): PendingIntent =
            PendingIntent.getActivity(context, meetingId?.hashCode() ?: 0,
                Intent(context, MainActivity::class.java).putExtra(EXTRA_OPEN, meetingId)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

        fun createChannels(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(NotificationChannel(CHANNEL_WORK, "Recording and transcribing", NotificationManager.IMPORTANCE_LOW))
            nm.createNotificationChannel(NotificationChannel(CHANNEL_DONE, "Notes ready", NotificationManager.IMPORTANCE_DEFAULT))
        }

        /**
         * After the app was killed (or the phone restarted): recordings still marked "recording" are closed and
         * transcribed from what was saved, and unfinished transcriptions are started again.
         */
        fun recover(context: Context) {
            if (Work.recording.value != null) return
            for (m in Store.loadAll()) {
                if (m.id in Work.queued.value) continue
                when (m.status) {
                    Meta.RECORDING -> {
                        val audio = File(m.folder, Store.AUDIO)
                        Wav.repair(audio)
                        if (Wav.durationSeconds(audio) < 1.0) {
                            Store.update(m.folder) { it.copy(status = Meta.FAILED, error = "The recording was interrupted before any audio was saved.") }
                        } else {
                            Store.update(m.folder) { it.copy(duration = Wav.durationSeconds(audio)) }
                            process(context, m.id, false)
                        }
                    }
                    Meta.TRANSCRIBING -> process(context, m.id, false)
                    Meta.SUMMARIZING -> process(context, m.id, true)
                }
            }
        }
    }
}
