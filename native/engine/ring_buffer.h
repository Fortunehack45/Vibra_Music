#ifndef VIBRA_RING_BUFFER_H
#define VIBRA_RING_BUFFER_H

#include <vector>
#include <atomic>
#include <algorithm>
#include <cstring>

namespace vibra {

/**
 * Lock-free Single-Producer Single-Consumer (SPSC) Audio Ring Buffer.
 * Units: audio frames (interleaved channels).
 */
class AudioRingBuffer {
private:
    std::vector<float> buffer;
    size_t capacityFrames = 0;
    int channels = 2;

    std::atomic<size_t> writeHead{0};
    std::atomic<size_t> readTail{0};

public:
    AudioRingBuffer() = default;

    void init(size_t frames, int numChannels = 2) {
        channels = numChannels;
        capacityFrames = frames + 1; // +1 to distinguish full from empty
        buffer.assign(capacityFrames * channels, 0.0f);
        writeHead.store(0, std::memory_order_relaxed);
        readTail.store(0, std::memory_order_relaxed);
    }

    void reset() {
        writeHead.store(0, std::memory_order_relaxed);
        readTail.store(0, std::memory_order_relaxed);
        std::fill(buffer.begin(), buffer.end(), 0.0f);
    }

    size_t availableRead() const {
        size_t head = writeHead.load(std::memory_order_acquire);
        size_t tail = readTail.load(std::memory_order_relaxed);
        if (head >= tail) {
            return head - tail;
        }
        return capacityFrames - (tail - head);
    }

    size_t availableWrite() const {
        size_t head = writeHead.load(std::memory_order_relaxed);
        size_t tail = readTail.load(std::memory_order_acquire);
        if (tail > head) {
            return tail - head - 1;
        }
        return capacityFrames - (head - tail) - 1;
    }

    size_t write(const float* data, size_t frames) {
        if (!data || frames == 0 || capacityFrames == 0) return 0;

        size_t canWrite = std::min(frames, availableWrite());
        if (canWrite == 0) return 0;

        size_t head = writeHead.load(std::memory_order_relaxed);
        size_t firstPart = std::min(canWrite, capacityFrames - head);
        size_t secondPart = canWrite - firstPart;

        std::memcpy(&buffer[head * channels], data, firstPart * channels * sizeof(float));
        if (secondPart > 0) {
            std::memcpy(&buffer[0], data + (firstPart * channels), secondPart * channels * sizeof(float));
        }

        size_t newHead = (head + canWrite) % capacityFrames;
        writeHead.store(newHead, std::memory_order_release);
        return canWrite;
    }

    size_t read(float* data, size_t frames) {
        if (!data || frames == 0 || capacityFrames == 0) return 0;

        size_t canRead = std::min(frames, availableRead());
        if (canRead == 0) return 0;

        size_t tail = readTail.load(std::memory_order_relaxed);
        size_t firstPart = std::min(canRead, capacityFrames - tail);
        size_t secondPart = canRead - firstPart;

        std::memcpy(data, &buffer[tail * channels], firstPart * channels * sizeof(float));
        if (secondPart > 0) {
            std::memcpy(data + (firstPart * channels), &buffer[0], secondPart * channels * sizeof(float));
        }

        size_t newTail = (tail + canRead) % capacityFrames;
        readTail.store(newTail, std::memory_order_release);
        return canRead;
    }
};

} // namespace vibra

#endif // VIBRA_RING_BUFFER_H
