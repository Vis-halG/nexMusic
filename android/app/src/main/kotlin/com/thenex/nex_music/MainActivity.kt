package com.thenex.nex_music

import android.content.Intent
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity shares its Flutter engine with the background audio
// service, so music and its lock screen controls keep working after the
// activity closes.
class MainActivity : AudioServiceActivity() {
    private val channelName = "com.thenex.nexmusic/media_tools"
    private var phoneChannel: MethodChannel? = null
    private var musicFeatures: MusicFeatures? = null

    /** Dart's pickMedia call, answered when the chooser closes. */
    private var pendingPick: MethodChannel.Result? = null

    /** A widget action that has not reached Dart yet. */
    private var pendingAction: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        NexPhone.createChannels(applicationContext)
        pendingAction = NexPhone.launchAction(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        NexPhone.launchAction(intent)?.let {
            pendingAction = it
            deliverPendingAction()
        }
    }

    override fun onResume() {
        super.onResume()
        TransferService.refresh(applicationContext)
    }

    /** Hands a widget action to a running app; a starting app asks for it. */
    private fun deliverPendingAction() {
        val action = pendingAction ?: return
        phoneChannel?.invokeMethod("launchAction", action, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (pendingAction == action) pendingAction = null
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}

            override fun notImplemented() {}
        })
    }

    /**
     * Opens the system chooser for audio and video files. Filtering by the
     * audio and video MIME families keeps every format selectable, and files
     * are not copied here: each one is copied only while it uploads.
     */
    private fun pickMedia(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("ALREADY_PICKING", "A file chooser is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "audio/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            pendingPick = result
            startActivityForResult(intent, PICK_MEDIA_REQUEST)
        } catch (error: Exception) {
            pendingPick = null
            result.error("NO_FILE_CHOOSER", error.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_MEDIA_REQUEST) return
        val result = pendingPick ?: return
        pendingPick = null
        if (resultCode != RESULT_OK || data == null) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip -> for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri) }
        if (uris.isEmpty()) data.data?.let { uris.add(it) }
        Thread {
            val files = uris.map { NexPhone.describe(applicationContext, it) }
            runOnUiThread { result.success(files) }
        }.start()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        musicFeatures = MusicFeatures(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.thenex.nexmusic/features")
            .setMethodCallHandler { call, result -> musicFeatures!!.handle(call,result) }
        phoneChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.thenex.nexmusic/phone",
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeLaunchAction" -> {
                        result.success(pendingAction)
                        pendingAction = null
                    }
                    "pickMedia" -> pickMedia(result)
                    else -> NexPhone.handle(applicationContext, call, result)
                }
            }
        }
        deliverPendingAction()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "extractAndTrimAudio") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val source = call.argument<String>("source")
                val startMs = call.argument<Number>("startMs")?.toLong() ?: 0L
                val endMs = call.argument<Number>("endMs")?.toLong() ?: Long.MAX_VALUE
                if (source.isNullOrBlank() || endMs <= startMs) {
                    result.error("INVALID_RANGE", "Choose a valid file and trim range.", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        val path = extractAndTrim(source, startMs, endMs)
                        runOnUiThread { result.success(path) }
                    } catch (error: Exception) {
                        runOnUiThread {
                            result.error("MEDIA_PROCESSING_FAILED", error.message, null)
                        }
                    }
                }.start()
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode,permissions,grantResults)
        musicFeatures?.permissions(requestCode,grantResults)
    }

    /**
     * Trims the first audio track of [source] to [startMs]–[endMs]. MP3 frames
     * are copied into an MP3 and AAC into an M4A without re-encoding (MediaMuxer
     * cannot put audio/mpeg into MP4). Anything else the phone can decode
     * (FLAC, WAV, Ogg, Opus, AMR, …) is converted to AAC in an M4A, or saved as
     * WAV when the phone's AAC encoder refuses to start. No network
     * downloader is used: [source] must be a user-selected local file or
     * Android content URI for media they are allowed to process.
     */
    private fun extractAndTrim(source: String, startMs: Long, endMs: Long): String {
        val extractor = openExtractor(source)
        val format = selectAudioTrack(extractor)
        return when (format.getString(MediaFormat.KEY_MIME).orEmpty()) {
            MediaFormat.MIMETYPE_AUDIO_MPEG -> trimMp3(extractor, format, startMs, endMs)
            MediaFormat.MIMETYPE_AUDIO_AAC -> try {
                copyAac(extractor, format, startMs, endMs)
            } catch (error: Exception) {
                transcodeRange(source, startMs, endMs)
            }
            else -> {
                extractor.release()
                transcodeRange(source, startMs, endMs)
            }
        }
    }

    private fun openExtractor(source: String): MediaExtractor {
        val extractor = MediaExtractor()
        try {
            if (source.startsWith("content://")) {
                contentResolver.openAssetFileDescriptor(Uri.parse(source), "r")?.use { descriptor ->
                    extractor.setDataSource(descriptor.fileDescriptor, descriptor.startOffset, descriptor.length)
                } ?: error("The selected file could not be opened.")
            } else {
                extractor.setDataSource(if (source.startsWith("file://")) Uri.parse(source).path!! else source)
            }
        } catch (error: Exception) {
            extractor.release()
            throw error
        }
        return extractor
    }

    /** Selects the first audio track, or releases [extractor] and fails. */
    private fun selectAudioTrack(extractor: MediaExtractor): MediaFormat {
        for (index in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(index)
            if (format.getString(MediaFormat.KEY_MIME).orEmpty().startsWith("audio/")) {
                extractor.selectTrack(index)
                return format
            }
        }
        extractor.release()
        error("This file does not contain a supported audio track.")
    }

    private fun exportFile(extension: String) =
        File(File(cacheDir, "nexmusic_exports").apply { mkdirs() }, "${UUID.randomUUID()}.$extension")

    private fun maxInputSize(format: MediaFormat) =
        if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
            format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE).coerceAtLeast(256 * 1024)
        } else {
            1024 * 1024
        }

    private fun copyAac(extractor: MediaExtractor, format: MediaFormat, startMs: Long, endMs: Long): String {
        val output = exportFile("m4a")
        var muxer: MediaMuxer? = null
        try {
            muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val outputTrack = muxer.addTrack(format)
            extractor.seekTo(startMs * 1000, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            muxer.start()
            val buffer = ByteBuffer.allocateDirect(maxInputSize(format))
            val info = MediaCodec.BufferInfo()
            val startUs = startMs * 1000
            val endUs = endMs * 1000
            var written = 0
            while (true) {
                val sampleTime = extractor.sampleTime
                if (sampleTime < 0 || sampleTime > endUs) break
                buffer.clear()
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                if (sampleTime >= startUs) {
                    info.set(0, size, sampleTime - startUs, extractor.sampleFlags)
                    muxer.writeSampleData(outputTrack, buffer, info)
                    written++
                }
                extractor.advance()
            }
            if (written == 0) error("The selected range contains no audio.")
            muxer.stop()
            return output.absolutePath
        } catch (error: Exception) {
            output.delete()
            throw error
        } finally {
            try {
                muxer?.release()
            } catch (ignored: Exception) {
            }
            extractor.release()
        }
    }

    private fun trimMp3(extractor: MediaExtractor, format: MediaFormat, startMs: Long, endMs: Long): String {
        val output = exportFile("mp3")
        val buffer = ByteBuffer.allocateDirect(maxInputSize(format))
        val startUs = startMs * 1000
        val endUs = endMs * 1000

        try {
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            FileOutputStream(output).use { stream ->
                while (true) {
                    val sampleTime = extractor.sampleTime
                    if (sampleTime < 0 || sampleTime > endUs) break
                    buffer.clear()
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    if (sampleTime >= startUs) {
                        val frame = ByteArray(size)
                        buffer.position(0)
                        buffer.limit(size)
                        buffer.get(frame)
                        stream.write(frame)
                    }
                    extractor.advance()
                }
            }
        } finally {
            extractor.release()
        }
        if (output.length() == 0L) {
            output.delete()
            error("The selected MP3 range contains no audio.")
        }
        return output.absolutePath
    }

    /**
     * Decodes the range to PCM, then saves it as AAC in an M4A. Some AAC
     * encoders refuse to configure (the Android 15 emulator's does), so WAV,
     * which needs no encoder, is the fallback.
     */
    private fun transcodeRange(source: String, startMs: Long, endMs: Long): String {
        val extractor = openExtractor(source)
        val format = selectAudioTrack(extractor)
        val pcm = exportFile("pcm")
        try {
            val (sampleRate, channels) = decodeToPcm(extractor, format, startMs * 1000, endMs * 1000, pcm)
            if (pcm.length() == 0L) error("The selected range contains no audio.")
            val m4a = exportFile("m4a")
            try {
                encodeToM4a(pcm, sampleRate, channels, m4a)
                return m4a.absolutePath
            } catch (ignored: Exception) {
                m4a.delete()
            }
            val wav = exportFile("wav")
            try {
                writeWav(pcm, sampleRate, channels, wav)
                return wav.absolutePath
            } catch (error: Exception) {
                wav.delete()
                throw error
            }
        } finally {
            pcm.delete()
        }
    }

    /** Wraps 16-bit PCM in a WAV header. */
    private fun writeWav(pcm: File, sampleRate: Int, channels: Int, output: File) {
        val dataBytes = pcm.length()
        if (dataBytes > Int.MAX_VALUE - 36) error("The trimmed audio is too long for a WAV file.")
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray(Charsets.US_ASCII))
            putInt((36 + dataBytes).toInt())
            put("WAVE".toByteArray(Charsets.US_ASCII))
            put("fmt ".toByteArray(Charsets.US_ASCII))
            putInt(16)
            putShort(1)
            putShort(channels.toShort())
            putInt(sampleRate)
            putInt(sampleRate * channels * 2)
            putShort((channels * 2).toShort())
            putShort(16)
            put("data".toByteArray(Charsets.US_ASCII))
            putInt(dataBytes.toInt())
        }
        FileOutputStream(output).use { out ->
            out.write(header.array())
            FileInputStream(pcm).use { it.copyTo(out, 64 * 1024) }
        }
    }

    /**
     * Writes the decoded range as 16-bit PCM with at most two channels and
     * returns its sample rate and channel count. Releases [extractor].
     */
    private fun decodeToPcm(
        extractor: MediaExtractor,
        format: MediaFormat,
        startUs: Long,
        endUs: Long,
        pcm: File,
    ): Pair<Int, Int> {
        val decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var encoding = AudioFormat.ENCODING_PCM_16BIT
        try {
            decoder.configure(format, null, null, 0)
            decoder.start()
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var idle = 0
            BufferedOutputStream(FileOutputStream(pcm)).use { out ->
                while (true) {
                    if (!inputDone) {
                        val index = decoder.dequeueInputBuffer(CODEC_TIMEOUT_US)
                        if (index >= 0) {
                            val buffer = decoder.getInputBuffer(index)!!
                            val size = extractor.readSampleData(buffer, 0)
                            val time = extractor.sampleTime
                            if (size < 0 || time > endUs) {
                                decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                decoder.queueInputBuffer(index, 0, size, time, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val index = decoder.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)
                    when {
                        index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val decoded = decoder.outputFormat
                            sampleRate = decoded.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = decoded.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            if (decoded.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                                encoding = decoded.getInteger(MediaFormat.KEY_PCM_ENCODING)
                            }
                        }
                        index >= 0 -> {
                            idle = 0
                            val buffer = decoder.getOutputBuffer(index)
                            if (buffer != null && info.size > 0) {
                                writePcm(out, buffer, info, sampleRate, channels, encoding, startUs, endUs)
                            }
                            decoder.releaseOutputBuffer(index, false)
                            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
                        }
                        inputDone && ++idle > STALL_LIMIT -> break
                    }
                }
            }
        } finally {
            try {
                decoder.stop()
            } catch (ignored: Exception) {
            }
            decoder.release()
            extractor.release()
        }
        return sampleRate to channels.coerceAtMost(2)
    }

    /** Copies the part of one decoded buffer that lies inside the range. */
    private fun writePcm(
        out: OutputStream,
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
        sampleRate: Int,
        channels: Int,
        encoding: Int,
        startUs: Long,
        endUs: Long,
    ) {
        val sampleBytes = when (encoding) {
            AudioFormat.ENCODING_PCM_16BIT -> 2
            AudioFormat.ENCODING_PCM_FLOAT -> 4
            else -> error("Unsupported PCM encoding $encoding")
        }
        val frameBytes = sampleBytes * channels
        val frames = info.size / frameBytes
        val first = if (info.presentationTimeUs >= startUs) {
            0
        } else {
            ((startUs - info.presentationTimeUs) * sampleRate / 1_000_000L).coerceAtMost(frames.toLong()).toInt()
        }
        val last = ((endUs - info.presentationTimeUs) * sampleRate / 1_000_000L).coerceIn(0L, frames.toLong()).toInt()
        if (last <= first) return
        if (sampleBytes == 2 && channels <= 2) {
            val bytes = ByteArray((last - first) * frameBytes)
            val view = buffer.duplicate()
            view.position(info.offset + first * frameBytes)
            view.get(bytes)
            out.write(bytes)
            return
        }
        // Float samples, or more than two channels: keep the first two as
        // 16-bit PCM.
        val outChannels = channels.coerceAtMost(2)
        val bytes = ByteArray((last - first) * outChannels * 2)
        val samples = buffer.duplicate().order(ByteOrder.nativeOrder())
        var position = 0
        for (frame in first until last) {
            val base = info.offset + frame * frameBytes
            for (channel in 0 until outChannels) {
                val sample = if (sampleBytes == 2) {
                    samples.getShort(base + channel * 2).toInt()
                } else {
                    (samples.getFloat(base + channel * 4).coerceIn(-1f, 1f) * 32767f).toInt()
                }
                bytes[position++] = sample.toByte()
                bytes[position++] = (sample shr 8).toByte()
            }
        }
        out.write(bytes)
    }

    private fun encodeToM4a(pcm: File, sampleRate: Int, channels: Int, output: File) {
        // Only the profile and bit rate are set: asking for a larger input
        // buffer made the software AAC encoder fail to configure. Input is fed
        // in whatever buffer size the encoder offers.
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, if (channels == 1) 96_000 else 160_000)
        }
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        val muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            encoder.configure(format, null, null, 0)
            encoder.start()
            val frameBytes = channels * 2
            val chunk = ByteArray(PCM_CHUNK_BYTES / frameBytes * frameBytes)
            val info = MediaCodec.BufferInfo()
            var track = -1
            var frames = 0L
            var inputDone = false
            var idle = 0
            FileInputStream(pcm).use { input ->
                while (true) {
                    if (!inputDone) {
                        val index = encoder.dequeueInputBuffer(CODEC_TIMEOUT_US)
                        if (index >= 0) {
                            val buffer = encoder.getInputBuffer(index)!!
                            buffer.clear()
                            val wanted = minOf(chunk.size, buffer.remaining() / frameBytes * frameBytes)
                            val read = readFully(input, chunk, wanted)
                            val timeUs = frames * 1_000_000L / sampleRate
                            if (read <= 0) {
                                encoder.queueInputBuffer(index, 0, 0, timeUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                buffer.put(chunk, 0, read)
                                encoder.queueInputBuffer(index, 0, read, timeUs, 0)
                                frames += read / frameBytes
                            }
                        }
                    }
                    val index = encoder.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)
                    when {
                        index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            track = muxer.addTrack(encoder.outputFormat)
                            muxer.start()
                        }
                        index >= 0 -> {
                            idle = 0
                            val data = encoder.getOutputBuffer(index)!!
                            val config = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                            if (!config && info.size > 0 && track >= 0) {
                                data.position(info.offset)
                                data.limit(info.offset + info.size)
                                muxer.writeSampleData(track, data, info)
                            }
                            encoder.releaseOutputBuffer(index, false)
                            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
                        }
                        inputDone && ++idle > STALL_LIMIT -> error("Encoding the trimmed audio stalled.")
                    }
                }
            }
            muxer.stop()
        } finally {
            try {
                encoder.stop()
            } catch (ignored: Exception) {
            }
            encoder.release()
            try {
                muxer.release()
            } catch (ignored: Exception) {
            }
        }
    }

    private fun readFully(input: FileInputStream, target: ByteArray, length: Int): Int {
        var total = 0
        while (total < length) {
            val read = input.read(target, total, length - total)
            if (read < 0) break
            total += read
        }
        return total
    }

    private companion object {
        const val PICK_MEDIA_REQUEST = 4242
        const val CODEC_TIMEOUT_US = 10_000L
        const val PCM_CHUNK_BYTES = 16 * 1024

        /** Empty 10 ms polls in a row after the input ended (about 5 s). */
        const val STALL_LIMIT = 500
    }
}
