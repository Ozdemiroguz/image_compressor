package com.oguzhan.image_compressor

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

/*
 * Plain-JVM unit tests for the paths that don't need the Android graphics stack.
 * The full decode/encode round-trip is covered by the example's integration test
 * on a real device (BitmapFactory needs a running Android runtime).
 *
 * Run with `./gradlew testDebugUnitTest` in `example/android/`.
 */
internal class ImageCompressorPluginTest {
    @Test
    fun encodeOnce_heic_reportsUnsupportedFormat() {
        val plugin = ImageCompressorPlugin()
        val call = MethodCall(
            "encodeOnce",
            mapOf(
                "bytes" to ByteArray(4),
                "quality" to 80,
                "format" to "heic",
                "autoOrient" to false,
            ),
        )
        val result = Mockito.mock(MethodChannel.Result::class.java)

        plugin.onMethodCall(call, result)

        // heic is rejected synchronously, before any bitmap work.
        Mockito.verify(result).error(
            Mockito.eq("unsupported_format"),
            Mockito.anyString(),
            Mockito.isNull(),
        )
    }

    @Test
    fun onMethodCall_unknownMethod_notImplemented() {
        val plugin = ImageCompressorPlugin()
        val call = MethodCall("nope", null)
        val result = Mockito.mock(MethodChannel.Result::class.java)

        plugin.onMethodCall(call, result)

        Mockito.verify(result).notImplemented()
    }
}
