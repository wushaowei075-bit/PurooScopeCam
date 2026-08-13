package com.puroo.pulai

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import kotlin.math.PI

class GyroStabilizer(
    context: Context,
    private val onCorrection: (x: Float, y: Float, rollDegrees: Float) -> Unit
) : SensorEventListener {
    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val rotationSensor = sensorManager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
        ?: sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    private val rotationMatrix = FloatArray(9)
    private val orientation = FloatArray(3)
    private val reference = FloatArray(3)
    private var hasReference = false
    var isEnabled: Boolean = true
        set(value) {
            field = value
            hasReference = false
            if (!value) onCorrection(0f, 0f, 0f)
        }

    fun start() {
        rotationSensor?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_FASTEST)
        }
    }

    fun stop() {
        sensorManager.unregisterListener(this)
        hasReference = false
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (!isEnabled) return
        SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
        SensorManager.getOrientation(rotationMatrix, orientation)
        if (!hasReference) {
            orientation.copyInto(reference)
            hasReference = true
            return
        }
        for (index in 0..2) {
            val delta = angleDelta(orientation[index], reference[index])
            reference[index] = wrapAngle(reference[index] + delta * 0.035f)
        }
        val yaw = angleDelta(orientation[0], reference[0])
        val pitch = angleDelta(orientation[1], reference[1])
        val roll = angleDelta(orientation[2], reference[2])
        onCorrection(
            (-yaw * 0.62f).coerceIn(-0.045f, 0.045f),
            (pitch * 0.62f).coerceIn(-0.045f, 0.045f),
            (-roll * 180f / PI.toFloat() * 0.18f).coerceIn(-1.2f, 1.2f)
        )
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun angleDelta(value: Float, referenceValue: Float): Float {
        return wrapAngle(value - referenceValue)
    }

    private fun wrapAngle(value: Float): Float {
        var result = value
        while (result > PI) result -= (2 * PI).toFloat()
        while (result < -PI) result += (2 * PI).toFloat()
        return result
    }
}
