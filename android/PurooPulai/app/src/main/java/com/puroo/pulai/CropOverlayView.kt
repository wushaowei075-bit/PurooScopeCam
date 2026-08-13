package com.puroo.pulai

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import kotlin.math.max
import kotlin.math.min

class CropOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : View(context, attrs) {
    private val cropPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(255, 220, 30)
        style = Paint.Style.STROKE
        strokeWidth = resources.displayMetrics.density * 1.5f
    }
    private val centerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(255, 220, 30)
        strokeWidth = resources.displayMetrics.density
    }
    private var correctionX = 0f
    private var correctionY = 0f
    private var cropScale = 1.08f

    fun updateCorrection(x: Float, y: Float, scale: Float) {
        correctionX = x.coerceIn(-0.08f, 0.08f)
        correctionY = y.coerceIn(-0.08f, 0.08f)
        cropScale = max(scale, 1.001f)
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cropWidth = width / cropScale
        val cropHeight = height / cropScale
        val halfWidth = cropWidth * 0.5f
        val halfHeight = cropHeight * 0.5f
        val centerX = min(max(width * (0.5f - correctionX), halfWidth), width - halfWidth)
        val centerY = min(max(height * (0.5f + correctionY), halfHeight), height - halfHeight)
        val rect = RectF(
            centerX - halfWidth,
            centerY - halfHeight,
            centerX + halfWidth,
            centerY + halfHeight
        )
        canvas.drawRect(rect, cropPaint)
        canvas.drawLine(centerX - 8f, centerY, centerX + 8f, centerY, centerPaint)
        canvas.drawLine(centerX, centerY - 8f, centerX, centerY + 8f, centerPaint)
    }
}
