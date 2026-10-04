package com.lumalex.dictionary

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.core.content.edit
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * Floating, permission-free dictionary window opened from Android's selected
 * text menu. It is an application Activity, not a SYSTEM_ALERT_WINDOW overlay,
 * so closing it naturally returns the reader to the source application.
 */
class ProcessTextActivity : MainActivity() {
    private companion object {
        const val CHANNEL_NAME = "local_dictionary/process_text_window"
        const val PREFERENCES_NAME = "process_text_window"
        const val MAXIMUM_SELECTED_TEXT_LENGTH = 256
        const val SAVE_DELAY_MILLIS = 180L
    }

    private data class FloatingBounds(
        val width: Int,
        val height: Int,
        val x: Int,
        val y: Int,
    )

    private val handler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var currentBounds: FloatingBounds? = null
    private var restoreBounds: FloatingBounds? = null
    private var isMaximized = false
    private var lastSafeScreenBounds: Rect? = null
    private var moveGestureStart: FloatingBounds? = null
    private var moveStartRawX = 0f
    private var moveStartRawY = 0f
    private var resizeGestureStart: FloatingBounds? = null
    private var resizeStartRawX = 0f
    private var resizeStartRawY = 0f
    private val touchSlop by lazy { ViewConfiguration.get(this).scaledTouchSlop }
    private val saveBounds = Runnable { persistCurrentBounds() }

    override fun getDartEntrypointFunctionName(): String = "processTextMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setFinishOnTouchOutside(true)
        window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.setDimAmount(0.16f)
        window.decorView.elevation = dp(12f).toFloat()
        installNativeGestureSurfaces()
        window.decorView.post { restoreFloatingBounds() }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSelectedText" -> result.success(selectedText())
                    "toggleMaximized" -> {
                        toggleMaximized()
                        result.success(isMaximized)
                    }
                    "close" -> {
                        result.success(null)
                        finish()
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        scheduleSafeAreaRecovery()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) scheduleSafeAreaRecovery()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (!isMaximized) persistCurrentBounds()
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }

    private fun selectedText(): String {
        if (intent.action != Intent.ACTION_PROCESS_TEXT) return ""
        return intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
            ?.toString()
            ?.trim()
            ?.replace(Regex("\\s+"), " ")
            ?.take(MAXIMUM_SELECTED_TEXT_LENGTH)
            .orEmpty()
    }

    private fun installNativeGestureSurfaces() {
        val moveSurface = View(this).apply {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            setOnTouchListener { view, event ->
                val handled = handleMoveTouch(event)
                if (event.actionMasked == MotionEvent.ACTION_UP) {
                    view.performClick()
                }
                handled
            }
        }
        addContentView(
            moveSurface,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(50f),
                Gravity.TOP or Gravity.START,
            ).apply {
                // The left side remains a generous native drag surface. Keep
                // the Flutter text-size, favorite and maximize actions on the
                // right unobstructed by this transparent gesture view.
                marginEnd = dp(146f)
            },
        )

        val resizeSurface = View(this).apply {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            setOnTouchListener { view, event ->
                val handled = handleResizeTouch(event)
                if (event.actionMasked == MotionEvent.ACTION_UP) {
                    view.performClick()
                }
                handled
            }
        }
        addContentView(
            resizeSurface,
            FrameLayout.LayoutParams(
                dp(42f),
                dp(42f),
                Gravity.BOTTOM or Gravity.END,
            ),
        )
    }

    private fun handleMoveTouch(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                moveGestureStart = currentBounds
                moveStartRawX = event.rawX
                moveStartRawY = event.rawY
            }
            MotionEvent.ACTION_MOVE -> {
                val start = moveGestureStart ?: return true
                if (isMaximized) return true
                val dx = event.rawX - moveStartRawX
                val dy = event.rawY - moveStartRawY
                if (kotlin.math.abs(dx) < touchSlop && kotlin.math.abs(dy) < touchSlop) {
                    return true
                }
                applyBounds(
                    clampToScreen(
                        start.copy(
                            x = start.x + dx.roundToInt(),
                            y = start.y + dy.roundToInt(),
                        ),
                    ),
                )
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                moveGestureStart = null
                if (!isMaximized) scheduleSave()
            }
        }
        return true
    }

    private fun handleResizeTouch(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (isMaximized) {
                    isMaximized = false
                    restoreBounds = null
                }
                resizeGestureStart = currentBounds
                resizeStartRawX = event.rawX
                resizeStartRawY = event.rawY
            }
            MotionEvent.ACTION_MOVE -> {
                val start = resizeGestureStart ?: return true
                val dx = event.rawX - resizeStartRawX
                val dy = event.rawY - resizeStartRawY
                if (kotlin.math.abs(dx) < touchSlop && kotlin.math.abs(dy) < touchSlop) {
                    return true
                }
                applyBounds(
                    clampToScreen(
                        start.copy(
                            width = start.width + dx.roundToInt(),
                            height = start.height + dy.roundToInt(),
                        ),
                    ),
                )
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                resizeGestureStart = null
                scheduleSave()
            }
        }
        return true
    }

    private fun restoreFloatingBounds() {
        val screen = safeScreenBounds()
        lastSafeScreenBounds = Rect(screen)
        val margin = dp(10f)
        val maximumWidth = (screen.width() - margin * 2).coerceAtLeast(1)
        val maximumHeight = (screen.height() - margin * 2).coerceAtLeast(1)
        val preferences = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
        val savedWidth = preferences.getFloat("width_dp", -1f)
        val savedHeight = preferences.getFloat("height_dp", -1f)
        val width = if (savedWidth > 0) {
            dp(savedWidth)
        } else {
            (screen.width() * 0.92f).roundToInt()
        }.coerceIn(minOf(dp(300f), maximumWidth), maximumWidth)
        val height = if (savedHeight > 0) {
            dp(savedHeight)
        } else {
            (screen.height() * 0.72f).roundToInt()
        }.coerceIn(minOf(dp(340f), maximumHeight), maximumHeight)
        val savedX = preferences.getFloat("x_dp", Float.NaN)
        val savedY = preferences.getFloat("y_dp", Float.NaN)
        val x = if (savedX.isNaN()) {
            screen.left + (screen.width() - width) / 2
        } else {
            dp(savedX)
        }
        val y = if (savedY.isNaN()) {
            screen.top + (screen.height() - height) / 2
        } else {
            dp(savedY)
        }
        applyBounds(
            clampToScreen(FloatingBounds(width, height, x, y)),
            persist = false,
        )
    }

    private fun toggleMaximized() {
        val bounds = currentBounds ?: return
        if (isMaximized) {
            isMaximized = false
            val restored = restoreBounds ?: bounds
            restoreBounds = null
            applyBounds(clampToScreen(restored), persist = false)
            scheduleSave()
            return
        }
        restoreBounds = bounds
        isMaximized = true
        applyBounds(maximizedBounds(safeScreenBounds()), persist = false)
    }

    private fun clampToScreen(
        candidate: FloatingBounds,
        screen: Rect = safeScreenBounds(),
    ): FloatingBounds {
        val margin = dp(10f)
        val maximumWidth = (screen.width() - margin * 2).coerceAtLeast(1)
        val maximumHeight = (screen.height() - margin * 2).coerceAtLeast(1)
        val minimumWidth = minOf(dp(300f), maximumWidth)
        val minimumHeight = minOf(dp(340f), maximumHeight)
        val width = candidate.width.coerceIn(minimumWidth, maximumWidth)
        val height = candidate.height.coerceIn(minimumHeight, maximumHeight)
        val minimumX = screen.left + margin
        val maximumX = (screen.right - margin - width).coerceAtLeast(minimumX)
        val minimumY = screen.top + margin
        val maximumY = (screen.bottom - margin - height).coerceAtLeast(minimumY)
        return FloatingBounds(
            width = width,
            height = height,
            x = candidate.x.coerceIn(minimumX, maximumX),
            y = candidate.y.coerceIn(minimumY, maximumY),
        )
    }

    private fun scheduleSafeAreaRecovery() {
        // Fold/unfold transitions can publish configuration and window metrics
        // on different frames. Recheck a few times, but only move the window
        // when the usable display bounds actually change.
        handler.post { recoverIntoCurrentSafeArea() }
        handler.postDelayed({ recoverIntoCurrentSafeArea() }, 180L)
        handler.postDelayed({ recoverIntoCurrentSafeArea() }, 480L)
    }

    private fun recoverIntoCurrentSafeArea() {
        val bounds = currentBounds ?: return
        val screen = safeScreenBounds()
        val previousScreen = lastSafeScreenBounds
        if (previousScreen == null) {
            lastSafeScreenBounds = Rect(screen)
            applyBounds(clampToScreen(bounds, screen), persist = false)
            return
        }
        if (previousScreen == screen) {
            applyBounds(clampToScreen(bounds, screen), persist = false)
            return
        }
        lastSafeScreenBounds = Rect(screen)
        if (isMaximized) {
            restoreBounds = restoreBounds?.let {
                repositionRelativeToScreen(it, previousScreen, screen)
            }
            applyBounds(maximizedBounds(screen), persist = false)
            return
        }
        applyBounds(
            repositionRelativeToScreen(bounds, previousScreen, screen),
            persist = false,
        )
        scheduleSave()
    }

    private fun repositionRelativeToScreen(
        bounds: FloatingBounds,
        previousScreen: Rect,
        nextScreen: Rect,
    ): FloatingBounds {
        val margin = dp(10f)
        val previousMinimumX = previousScreen.left + margin
        val previousMaximumX =
            (previousScreen.right - margin - bounds.width).coerceAtLeast(previousMinimumX)
        val previousMinimumY = previousScreen.top + margin
        val previousMaximumY =
            (previousScreen.bottom - margin - bounds.height).coerceAtLeast(previousMinimumY)
        val horizontalFraction = positionFraction(
            bounds.x,
            previousMinimumX,
            previousMaximumX,
        )
        val verticalFraction = positionFraction(
            bounds.y,
            previousMinimumY,
            previousMaximumY,
        )

        val resized = clampToScreen(
            bounds.copy(x = nextScreen.left, y = nextScreen.top),
            nextScreen,
        )
        val nextMinimumX = nextScreen.left + margin
        val nextMaximumX =
            (nextScreen.right - margin - resized.width).coerceAtLeast(nextMinimumX)
        val nextMinimumY = nextScreen.top + margin
        val nextMaximumY =
            (nextScreen.bottom - margin - resized.height).coerceAtLeast(nextMinimumY)
        return clampToScreen(
            resized.copy(
                x = nextMinimumX +
                    ((nextMaximumX - nextMinimumX) * horizontalFraction).roundToInt(),
                y = nextMinimumY +
                    ((nextMaximumY - nextMinimumY) * verticalFraction).roundToInt(),
            ),
            nextScreen,
        )
    }

    private fun positionFraction(value: Int, minimum: Int, maximum: Int): Float {
        if (maximum <= minimum) return 0.5f
        return ((value - minimum).toFloat() / (maximum - minimum))
            .coerceIn(0f, 1f)
    }

    private fun maximizedBounds(screen: Rect): FloatingBounds {
        val margin = dp(6f)
        return FloatingBounds(
            width = (screen.width() - margin * 2).coerceAtLeast(1),
            height = (screen.height() - margin * 2).coerceAtLeast(1),
            x = screen.left + margin,
            y = screen.top + margin,
        )
    }

    private fun applyBounds(bounds: FloatingBounds, persist: Boolean = true) {
        currentBounds = bounds
        window.attributes = window.attributes.apply {
            gravity = Gravity.TOP or Gravity.START
            width = bounds.width
            height = bounds.height
            x = bounds.x
            y = bounds.y
        }
        if (persist && !isMaximized) scheduleSave()
    }

    private fun scheduleSave() {
        handler.removeCallbacks(saveBounds)
        handler.postDelayed(saveBounds, SAVE_DELAY_MILLIS)
    }

    private fun persistCurrentBounds() {
        val bounds = currentBounds ?: return
        if (isMaximized) return
        getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE).edit {
            putFloat("width_dp", pxToDp(bounds.width))
            putFloat("height_dp", pxToDp(bounds.height))
            putFloat("x_dp", pxToDp(bounds.x))
            putFloat("y_dp", pxToDp(bounds.y))
        }
    }

    private fun safeScreenBounds(): Rect {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val metrics = windowManager.maximumWindowMetrics
            val bounds = Rect(metrics.bounds)
            val insets = metrics.windowInsets.getInsetsIgnoringVisibility(
                WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
            )
            val safe = Rect(
                bounds.left + insets.left,
                bounds.top + insets.top,
                bounds.right - insets.right,
                bounds.bottom - insets.bottom,
            )
            if (safe.width() > 0 && safe.height() > 0) return safe
            return bounds
        }
        val visible = Rect()
        @Suppress("DEPRECATION")
        window.decorView.getWindowVisibleDisplayFrame(visible)
        if (visible.width() > 0 && visible.height() > 0) return visible
        return Rect(
            0,
            0,
            resources.displayMetrics.widthPixels,
            resources.displayMetrics.heightPixels,
        )
    }

    private fun dp(value: Float): Int =
        (value * resources.displayMetrics.density).roundToInt()

    private fun pxToDp(value: Int): Float = value / resources.displayMetrics.density
}
