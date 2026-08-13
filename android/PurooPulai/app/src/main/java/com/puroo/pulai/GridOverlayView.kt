package com.puroo.pulai

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View

class GridOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : View(context, attrs) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(92, 255, 255, 255)
        strokeWidth = resources.displayMetrics.density * 0.7f
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val thirdWidth = width / 3f
        val thirdHeight = height / 3f
        canvas.drawLine(thirdWidth, 0f, thirdWidth, height.toFloat(), paint)
        canvas.drawLine(thirdWidth * 2f, 0f, thirdWidth * 2f, height.toFloat(), paint)
        canvas.drawLine(0f, thirdHeight, width.toFloat(), thirdHeight, paint)
        canvas.drawLine(0f, thirdHeight * 2f, width.toFloat(), thirdHeight * 2f, paint)
    }
}
