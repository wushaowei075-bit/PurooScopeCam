package com.puroo.pulai

import android.content.Context
import android.graphics.LinearGradient
import android.graphics.Shader
import android.util.AttributeSet
import androidx.appcompat.widget.AppCompatTextView

class DopamineTextView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = android.R.attr.textViewStyle
) : AppCompatTextView(context, attrs, defStyleAttr) {

    init {
        includeFontPadding = false
        typeface = android.graphics.Typeface.create("sans", android.graphics.Typeface.NORMAL)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w <= 0) return
        paint.shader = LinearGradient(
            0f,
            0f,
            w.toFloat(),
            0f,
            intArrayOf(0xFFFF38C1.toInt(), 0xFFFFE63D.toInt(), 0xFF8EF04F.toInt(), 0xFF3DDBF2.toInt()),
            null,
            Shader.TileMode.CLAMP
        )
        invalidate()
    }
}
