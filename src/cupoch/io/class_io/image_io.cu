#include "cupoch/io/class_io/image_io.h"
#include "cupoch/geometry/image.h"
#include "cupoch/utility/helper.h"

using namespace cupoch;
using namespace cupoch::io;

void HostImage::FromDevice(const geometry::Image& image) {
    data_.resize(image.data_.size());
    Prepare(image.width_, image.height_, image.num_of_channels_, image.bytes_per_channel_);
    thrust::copy(image.data_.begin(), image.data_.end(), data_.begin());
}

void HostImage::ToDevice(geometry::Image& image) const {
    image.Prepare(width_, height_, num_of_channels_, bytes_per_channel_);
    image.data_.resize(data_.size());
    thrust::copy(data_.begin(), data_.end(), image.data_.begin());
}

void HostImage::Clear() {
    data_.clear();
    width_ = 0;
    height_ = 0;
    num_of_channels_ = 0;
    bytes_per_channel_ = 0;
}

HostImage& HostImage::Prepare(int width,
    int height,
    int num_of_channels,
    int bytes_per_channel) {
    width_ = width;
    height_ = height;
    num_of_channels_ = num_of_channels;
    bytes_per_channel_ = bytes_per_channel;
    data_.resize(width_ * height_ * num_of_channels_ * bytes_per_channel_);
    return *this;
}