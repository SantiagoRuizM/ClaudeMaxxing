package com.claudemaxxing.claudemaxxing

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.ToneGenerator
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import android.view.KeyEvent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * The ears, mouth and buttons of a call with a session; what to say and send is decided in lib/call.dart.
 * - Listening: the headset's microphone (Bluetooth SCO) and Android's recognizer.
 * - The rest of the time: media audio, the only mode in which a headset sends play/pause and next to an app.
 *   In call audio it only sends answer and hang up.
 */
class CallService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var audio: AudioManager
    private var wake: PowerManager.WakeLock? = null
    private var session: MediaSession? = null
    private var focus: AudioFocusRequest? = null
    private var tts: TextToSpeech? = null
    private var ttsOk = false
    private var silence: AudioTrack? = null
    private var recognizer: SpeechRecognizer? = null
    private var locale = "es-US"
    private var labels: Bundle = Bundle.EMPTY
    private var status = ""
    private var canAccept = false
    private var interrupted = false
    private var headsetMic = false
    private var mediaAudioAt = 0L // when media audio is back after the headset's microphone

    private var utterance = 0 // the one being spoken: callbacks of older ones are ignored
    private var listening = false
    private var round = 0
    private var finishing = false
    private var heard = ""
    private var partial = ""
    private var quietRounds = 0
    private var failures = 0
    private var listenUntil = 0L

    // A real call rings or is under way. This service never changes the audio mode, so any other mode is another app's.
    private val watchCalls = object : Runnable {
        override fun run() {
            val busy = audio.mode in listOf(AudioManager.MODE_RINGTONE, AudioManager.MODE_IN_CALL, AudioManager.MODE_IN_COMMUNICATION)
            if (busy != interrupted) {
                interrupted = busy
                if (busy) {
                    hush()
                    silence?.release()
                    silence = null
                } else {
                    requestFocus()
                    playSilence(AudioAttributes.USAGE_MEDIA)
                }
                session?.isActive = !busy
                emit(if (busy) "interrupted" else "resumed")
            }
            main.postDelayed(this, 1000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        audio = getSystemService(AUDIO_SERVICE) as AudioManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (val action = intent?.action) {
            null -> if (instance == null) begin(intent?.extras) else emit("ready")
            HANG_UP -> {
                emit("hangup")
                stopSelf()
            }
            // A notification's button left over from a call that ended.
            else -> if (instance == null) stopSelf() else button(action)
        }
        return START_NOT_STICKY
    }

    private fun begin(extras: Bundle?) {
        if (extras == null) return stopSelf()
        labels = extras
        locale = extras.getString("locale") ?: locale
        status = extras.getString("status").orEmpty()
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                startForeground(NOTIFICATION, notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(NOTIFICATION, notification())
            }
        } catch (e: RuntimeException) {
            Log.e(TAG, "cannot start in the foreground", e)
            emit("failed")
            return stopSelf()
        }
        instance = this
        wake = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "claudemaxxing:call")
            .apply { acquire(MAX_CALL_MS) }
        main.postDelayed({
            emit("hangup")
            stopSelf()
        }, MAX_CALL_MS)

        session = MediaSession(this, "ClaudeMaxxing").apply {
            @Suppress("DEPRECATION")
            setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            setCallback(buttons, main)
            setPlaybackState(PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS)
                .setState(PlaybackState.STATE_PLAYING, 0, 1f)
                .build())
            isActive = true
        }
        requestFocus()
        playSilence(AudioAttributes.USAGE_MEDIA)
        tts = TextToSpeech(this) { code ->
            main.post {
                val engine = tts ?: return@post
                if (code == TextToSpeech.SUCCESS) {
                    val wanted = Locale.forLanguageTag(locale)
                    ttsOk = engine.setLanguage(wanted) >= TextToSpeech.LANG_AVAILABLE ||
                        engine.setLanguage(Locale(wanted.language)) >= TextToSpeech.LANG_AVAILABLE
                    engine.setAudioAttributes(attributes(AudioAttributes.USAGE_MEDIA))
                    engine.setOnUtteranceProgressListener(progress)
                }
                if (!ttsOk) {
                    // A call without a voice is no use with the phone in a pocket: say so while it is still in the hand.
                    emit("failed")
                    stopSelf()
                    return@post
                }
                main.post(watchCalls)
                emit("ready")
            }
        }
    }

    fun handle(call: MethodCall) {
        when (call.method) {
            "say" -> say(call.argument<String>("text").orEmpty(), call.argument<Boolean>("chime") == true)
            "listen" -> listen()
            "finish" -> finishListening()
            "hush" -> hush()
            "status" -> {
                status = call.argument<String>("text").orEmpty()
                canAccept = call.argument<Boolean>("accept") == true
                (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION, notification())
            }
        }
    }

    // ---------------------------------------------------------------- speaking

    private val progress = object : UtteranceProgressListener() {
        override fun onStart(id: String?) {}

        override fun onDone(id: String?) {
            main.post { spoken(id, true) }
        }

        @Deprecated("Deprecated in Java")
        override fun onError(id: String?) {
            main.post { spoken(id, false) }
        }

        override fun onError(id: String?, code: Int) {
            main.post { spoken(id, false) }
        }
    }

    private fun spoken(id: String?, ok: Boolean) {
        if (id != "$utterance") return
        utterance++
        emit("said", mapOf("ok" to ok))
    }

    private fun say(text: String, chime: Boolean) {
        hush()
        val id = ++utterance
        if (interrupted) {
            main.post { spoken("$id", false) }
            return
        }
        // Back from SCO to A2DP takes a moment, and the first words would be lost.
        var wait = maxOf(150L, mediaAudioAt - SystemClock.elapsedRealtime())
        playSilence(AudioAttributes.USAGE_MEDIA)
        if (chime) {
            main.postDelayed({ if (id == utterance) beep(ToneGenerator.TONE_PROP_ACK) }, wait)
            wait += 700
        }
        main.postDelayed({
            if (id != utterance) return@postDelayed
            val cut = text.take(TextToSpeech.getMaxSpeechInputLength() - 1)
            if (tts?.speak(cut, TextToSpeech.QUEUE_FLUSH, null, "$id") != TextToSpeech.SUCCESS) spoken("$id", false)
        }, wait)
    }

    private fun hush() {
        utterance++
        tts?.stop()
        stopRecognizer()
    }

    private fun beep(tone: Int) {
        try {
            val generator = ToneGenerator(if (headsetMic) AudioManager.STREAM_VOICE_CALL else AudioManager.STREAM_MUSIC, 70)
            generator.startTone(tone, 250)
            main.postDelayed({ generator.release() }, 500)
        } catch (e: RuntimeException) {
            Log.w(TAG, "no tone", e)
        }
    }

    // ---------------------------------------------------------------- listening

    private fun listen() {
        hush()
        if (interrupted) return
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            emit("heard", mapOf("ok" to false, "text" to "", "headset" to false))
            return
        }
        listening = true
        finishing = false
        heard = ""
        partial = ""
        quietRounds = 0
        failures = 0
        listenUntil = SystemClock.elapsedRealtime() + MAX_LISTEN_MS
        headsetMic = useHeadsetMic()
        // The route to a headset only holds while this app plays voice-call audio.
        if (headsetMic) playSilence(AudioAttributes.USAGE_VOICE_COMMUNICATION)
        val mine = ++round
        main.postDelayed({
            if (listening && mine == round) {
                beep(ToneGenerator.TONE_PROP_BEEP)
                main.postDelayed({ if (listening && mine == round) recognize() }, 300)
            }
        }, if (headsetMic) 1200L else 100L)
    }

    // Android's recognizer ends at each pause, so rounds are joined until one brings no words.
    private fun recognize() {
        recognizer?.destroy()
        val mine = ++round
        partial = ""
        fun current() = listening && mine == round
        recognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
            setRecognitionListener(object : RecognitionListener {
                override fun onResults(results: Bundle?) {
                    if (!current()) return
                    failures = 0
                    roundEnded(words(results).ifBlank { partial })
                }

                override fun onPartialResults(results: Bundle?) {
                    if (!current()) return
                    val text = words(results)
                    if (text.isNotBlank()) partial = text
                }

                override fun onError(error: Int) {
                    if (!current()) return
                    when {
                        error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> roundEnded(partial)
                        finishing -> roundEnded(partial)
                        ++failures <= 2 -> {
                            append(partial)
                            partial = ""
                            main.postDelayed({ if (current()) recognize() }, 600)
                        }
                        else -> {
                            Log.w(TAG, "recognizer error $error")
                            append(partial)
                            endListening(false) // never send half a sentence as if it were whole
                        }
                    }
                }

                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                .putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName))
        }
    }

    private fun words(results: Bundle?): String =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()

    private fun append(text: String) {
        if (text.isNotBlank()) heard = "$heard ${text.trim()}".trim()
    }

    private fun roundEnded(text: String) {
        append(text)
        if (text.isBlank()) quietRounds++ else quietRounds = 0
        val silent = quietRounds >= (if (heard.isEmpty()) 2 else 1)
        if (finishing || silent || SystemClock.elapsedRealtime() >= listenUntil) endListening(true) else recognize()
    }

    private fun finishListening() {
        if (!listening || finishing) return
        finishing = true
        recognizer?.stopListening()
        // Not every recognizer answers a stop.
        val mine = round
        main.postDelayed({ if (listening && mine == round) roundEnded(partial) }, if (recognizer == null) 0L else 2500L)
    }

    private fun endListening(ok: Boolean) {
        val text = heard
        val headset = headsetMic
        stopRecognizer()
        emit("heard", mapOf("ok" to ok, "text" to text, "headset" to headset))
    }

    private fun stopRecognizer() {
        if (!listening) return
        listening = false
        round++
        recognizer?.destroy()
        recognizer = null
        if (headsetMic) {
            releaseHeadsetMic()
            mediaAudioAt = SystemClock.elapsedRealtime() + 900
        }
        headsetMic = false
        playSilence(AudioAttributes.USAGE_MEDIA)
    }

    private fun useHeadsetMic(): Boolean = try {
        if (Build.VERSION.SDK_INT >= 31) {
            val types = listOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET)
            val device = audio.availableCommunicationDevices.firstOrNull { it.type in types }
            device != null && audio.setCommunicationDevice(device)
        } else {
            @Suppress("DEPRECATION")
            if (audio.isBluetoothScoAvailableOffCall && audio.isBluetoothA2dpOn) {
                audio.startBluetoothSco()
                true
            } else {
                false
            }
        }
    } catch (e: RuntimeException) {
        Log.w(TAG, "no headset microphone", e)
        false
    }

    private fun releaseHeadsetMic() {
        if (Build.VERSION.SDK_INT >= 31) {
            audio.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            audio.stopBluetoothSco()
        }
    }

    // ---------------------------------------------------------------- buttons

    private val buttons = object : MediaSession.Callback() {
        // Handled here: the default waits to tell a double press apart, and the headset already did that.
        override fun onMediaButtonEvent(intent: Intent): Boolean {
            @Suppress("DEPRECATION")
            val key = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT) ?: return false
            val name = when (key.keyCode) {
                KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> PRIMARY
                KeyEvent.KEYCODE_MEDIA_NEXT -> TALK
                KeyEvent.KEYCODE_MEDIA_PREVIOUS -> REPLAY
                else -> return false
            }
            if (key.action == KeyEvent.ACTION_DOWN && key.repeatCount == 0) {
                Log.i(TAG, "button ${KeyEvent.keyCodeToString(key.keyCode)} -> $name")
                button(name)
            }
            return true
        }

        override fun onPlay() = button(PRIMARY)
        override fun onPause() = button(PRIMARY)
        override fun onSkipToNext() = button(TALK)
        override fun onSkipToPrevious() = button(REPLAY)
    }

    private fun button(name: String) {
        if (!interrupted) emit("button", mapOf("name" to name))
    }

    // ---------------------------------------------------------------- audio and notification

    private fun attributes(usage: Int): AudioAttributes = AudioAttributes.Builder()
        .setUsage(usage)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    /** A silent loop: media buttons go to the app that last played audio, and the voice is another app's (TTS). */
    private fun playSilence(usage: Int) {
        silence?.release()
        silence = null
        try {
            val frames = 8000
            silence = AudioTrack(attributes(usage),
                AudioFormat.Builder().setSampleRate(frames).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build(),
                frames * 2, AudioTrack.MODE_STATIC, AudioManager.AUDIO_SESSION_ID_GENERATE
            ).apply {
                write(ShortArray(frames), 0, frames)
                setLoopPoints(0, frames, -1)
                play()
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "no silent track", e)
        }
    }

    private val focusChanged = AudioManager.OnAudioFocusChangeListener { }

    private fun requestFocus() {
        if (Build.VERSION.SDK_INT >= 26) {
            val request = focus ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes(AudioAttributes.USAGE_MEDIA))
                .setOnAudioFocusChangeListener(focusChanged, main)
                .build().also { focus = it }
            audio.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(focusChanged, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
    }

    private fun notification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
                NotificationChannel(CHANNEL, labels.getString("channel") ?: "Call", NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        fun action(name: String, label: String) {
            val intent = PendingIntent.getService(this, 0, Intent(this, CallService::class.java).setAction(name),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            @Suppress("DEPRECATION")
            builder.addAction(Notification.Action.Builder(R.drawable.ic_stat_egg, labels.getString(label), intent).build())
        }
        if (canAccept) action(PRIMARY, "acceptLabel")
        action(TALK, "talkLabel")
        action(HANG_UP, "hangUpLabel")
        // Only the state: what Claude said doesn't show on the lock screen.
        return builder
            .setSmallIcon(R.drawable.ic_stat_egg)
            .setContentTitle(labels.getString("title"))
            .setContentText(status)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(PendingIntent.getActivity(this, 0,
                packageManager.getLaunchIntentForPackage(packageName), PendingIntent.FLAG_IMMUTABLE))
            .build()
    }

    private fun emit(method: String, args: Any? = null) {
        channel?.invokeMethod(method, args)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        emit("hangup")
        stopSelf()
    }

    override fun onDestroy() {
        if (instance == this) {
            hush()
            instance = null
            emit("hangup")
        }
        main.removeCallbacksAndMessages(null)
        tts?.shutdown()
        tts = null
        silence?.release()
        session?.release()
        if (Build.VERSION.SDK_INT >= 26) {
            focus?.let { audio.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(focusChanged)
        }
        wake?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }

    companion object {
        var channel: MethodChannel? = null
        var instance: CallService? = null
            private set
        val EXTRAS = listOf("locale", "title", "status", "channel", "acceptLabel", "talkLabel", "hangUpLabel")

        private const val TAG = "ClaudeCall"
        private const val CHANNEL = "session_call"
        private const val NOTIFICATION = 2 // 1 is the sessions' (lib/notify.dart)
        private const val PRIMARY = "primary"
        private const val TALK = "talk"
        private const val REPLAY = "replay"
        private const val HANG_UP = "hangup"
        private const val MAX_LISTEN_MS = 3 * 60_000L

        // shortcut: a call ends after 4 hours, renew the wake lock if walks get longer.
        private const val MAX_CALL_MS = 4 * 60 * 60_000L
    }
}
