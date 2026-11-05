package com.fortune.vibramusic.data.db

import androidx.room.TypeConverter
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * TypeConverters storing FloatArray and LongArray as raw BLOBs (ByteBuffer)
 * for compact, zero-overhead SQLite storage.
 */
class MixTypeConverters {

    @TypeConverter
    fun fromFloatArray(array: FloatArray?): ByteArray? {
        if (array == null) return null
        val byteBuffer = ByteBuffer.allocate(array.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (f in array) {
            byteBuffer.putFloat(f)
        }
        return byteBuffer.array()
    }

    @TypeConverter
    fun toFloatArray(bytes: ByteArray?): FloatArray? {
        if (bytes == null || bytes.isEmpty()) return FloatArray(0)
        val byteBuffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val array = FloatArray(bytes.size / 4)
        for (i in array.indices) {
            array[i] = byteBuffer.float
        }
        return array
    }

    @TypeConverter
    fun fromLongArray(array: LongArray?): ByteArray? {
        if (array == null) return null
        val byteBuffer = ByteBuffer.allocate(array.size * 8).order(ByteOrder.LITTLE_ENDIAN)
        for (l in array) {
            byteBuffer.putLong(l)
        }
        return byteBuffer.array()
    }

    @TypeConverter
    fun toLongArray(bytes: ByteArray?): LongArray? {
        if (bytes == null || bytes.isEmpty()) return LongArray(0)
        val byteBuffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val array = LongArray(bytes.size / 8)
        for (i in array.indices) {
            array[i] = byteBuffer.long
        }
        return array
    }
}
