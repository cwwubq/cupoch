#include "cupoch/geometry/pointcloud.h"
#include "cupoch/geometry/kdtree_flann.h"
#include "cupoch/utility/console.h"
#include "cupoch/utility/helper.h"
#include <thrust/gather.h>
#include <thrust/inner_product.h>

using namespace cupoch;
using namespace cupoch::geometry;

namespace {

struct compute_key_functor {
    compute_key_functor(const Eigen::Vector3f& voxel_min_bound, float voxel_size)
        : voxel_min_bound_(voxel_min_bound), voxel_size_(voxel_size) {};
    const Eigen::Vector3f voxel_min_bound_;
    const float voxel_size_;
    __device__
    Eigen::Vector3i operator()(const Eigen::Vector3f_u& pt) {
        auto ref_coord = (pt - voxel_min_bound_) / voxel_size_;
        return Eigen::Vector3i(int(floor(ref_coord(0))), int(floor(ref_coord(1))), int(floor(ref_coord(2))));
    }
};

template<typename OutputIterator, class... Args>
__host__
int CalcAverageByKey(thrust::device_vector<Eigen::Vector3i>& keys,
                     OutputIterator buf_begins, OutputIterator output_begins) {
    const size_t n = keys.size();
    thrust::sort_by_key(keys.begin(), keys.end(), buf_begins);

    thrust::device_vector<Eigen::Vector3i> keys_out(n);
    thrust::device_vector<int> counts(n);
    auto end1 = thrust::reduce_by_key(keys.begin(), keys.end(),
                                      thrust::make_constant_iterator(1),
                                      keys_out.begin(), counts.begin());
    int n_out = thrust::distance(counts.begin(), end1.second);
    counts.resize(n_out);

    thrust::equal_to<Eigen::Vector3i> binary_pred;
    add_tuple_functor<Args...> add_func;
    auto end2 = thrust::reduce_by_key(keys.begin(), keys.end(), buf_begins,
                                      keys_out.begin(), output_begins,
                                      binary_pred, add_func);

    devided_tuple_functor<Args...> dv_func;
    thrust::transform(output_begins, output_begins + n_out,
                      counts.begin(), output_begins,
                      dv_func);
    return n_out;
}

struct stride_copy_functor {
    stride_copy_functor(const Eigen::Vector3f_u* data, int every_k_points)
        : data_(data), every_k_points_(every_k_points) {};
    const Eigen::Vector3f_u* data_;
    const int every_k_points_;
    __device__
    Eigen::Vector3f_u operator() (int idx) const {
        return data_[idx * every_k_points_];
    }
};

struct has_radius_points_functor {
    has_radius_points_functor(const int* indices, int n_points) : indices_(indices), n_points_(n_points) {};
    const int* indices_;
    const int n_points_;
    __device__
    bool operator() (int idx) const {
        int count = 0;
        for (int i = 0; i < NUM_MAX_NN; ++i) {
            if (indices_[idx * NUM_MAX_NN + i] >= 0) count++;
        }
        return (count > n_points_);
    }
};

struct average_distance_functor {
    average_distance_functor(const float* distance) : distance_(distance) {};
    const float* distance_;
    __device__
    float operator() (int idx) const {
        int count = 0;
        float avg = 0;
        for (int i = 0; i < NUM_MAX_NN; ++i) {
            const float d = distance_[idx * NUM_MAX_NN + i];
            if (std::isinf(d) || d < 0.0) continue;
            avg += d;
            count++;
        }
        return (count == 0) ? -1.0 : avg / (float)count;
    }
};

struct check_distance_threshold_functor {
    check_distance_threshold_functor(const float* distances, float distance_threshold)
        : distances_(distances), distance_threshold_(distance_threshold) {};
    const float* distances_;
    const float distance_threshold_;
    __device__
    bool operator() (int idx) const {
        return (distances_[idx] > 0 && distances_[idx] < distance_threshold_);
    }
};

}

std::shared_ptr<PointCloud> PointCloud::SelectDownSample(const thrust::device_vector<size_t> &indices, bool invert) const {
    auto output = std::make_shared<PointCloud>();
    const bool has_normals = HasNormals();
    const bool has_colors = HasColors();

    output->points_.resize(indices.size());
    thrust::gather(indices.begin(), indices.end(), points_.begin(), output->points_.begin());
    if (HasNormals()) {
        output->normals_.resize(indices.size());
        thrust::gather(indices.begin(), indices.end(), normals_.begin(), output->normals_.begin());
    }
    if (HasColors()) {
        output->colors_.resize(indices.size());
        thrust::gather(indices.begin(), indices.end(), colors_.begin(), output->colors_.begin());
    }
    return output;
}

std::shared_ptr<PointCloud> PointCloud::VoxelDownSample(float voxel_size) const {
    auto output = std::make_shared<PointCloud>();
    if (voxel_size <= 0.0) {
        utility::LogWarning("[VoxelDownSample] voxel_size <= 0.\n");
        return output;
    }

    const Eigen::Vector3f voxel_size3 = Eigen::Vector3f(voxel_size, voxel_size, voxel_size);
    const Eigen::Vector3f voxel_min_bound = GetMinBound() - voxel_size3 * 0.5;
    const Eigen::Vector3f voxel_max_bound = GetMaxBound() + voxel_size3 * 0.5;

    if (voxel_size * std::numeric_limits<int>::max() < (voxel_max_bound - voxel_min_bound).maxCoeff()) {
        utility::LogWarning("[VoxelDownSample] voxel_size is too small.\n");
        return output;
    }

    const int n = points_.size();
    const bool has_normals = HasNormals();
    const bool has_colors = HasColors();
    compute_key_functor ck_func(voxel_min_bound, voxel_size);
    thrust::device_vector<Eigen::Vector3i> keys(n);
    thrust::transform(points_.begin(), points_.end(), keys.begin(), ck_func);

    thrust::device_vector<Eigen::Vector3f_u> sorted_points = points_;
    output->points_.resize(n);
    if (!has_normals && !has_colors) {
        typedef thrust::tuple<thrust::device_vector<Eigen::Vector3f_u>::iterator> IteratorTuple;
        typedef thrust::zip_iterator<IteratorTuple> ZipIterator;
        auto n_out = CalcAverageByKey<ZipIterator, Eigen::Vector3f_u>(keys,
                    thrust::make_zip_iterator(thrust::make_tuple(sorted_points.begin())),
                    thrust::make_zip_iterator(thrust::make_tuple(output->points_.begin())));
        output->points_.resize(n_out);
    } else if (has_normals && !has_colors) {
        thrust::device_vector<Eigen::Vector3f_u> sorted_normals = normals_;
        output->normals_.resize(n);
        typedef thrust::tuple<thrust::device_vector<Eigen::Vector3f_u>::iterator, thrust::device_vector<Eigen::Vector3f_u>::iterator> IteratorTuple;
        typedef thrust::zip_iterator<IteratorTuple> ZipIterator;
        auto n_out = CalcAverageByKey<ZipIterator, Eigen::Vector3f_u, Eigen::Vector3f_u>(keys,
                    thrust::make_zip_iterator(thrust::make_tuple(sorted_points.begin(), sorted_normals.begin())),
                    thrust::make_zip_iterator(thrust::make_tuple(output->points_.begin(), output->normals_.begin())));
        output->points_.resize(n_out);
        output->normals_.resize(n_out);
        thrust::for_each(output->normals_.begin(), output->normals_.end(), [] __device__ (Eigen::Vector3f_u& nl) {nl.normalize();});
    } else if (!has_normals && has_colors) {
        thrust::device_vector<Eigen::Vector3f_u> sorted_colors = colors_;
        output->colors_.resize(n);
        typedef thrust::tuple<thrust::device_vector<Eigen::Vector3f_u>::iterator, thrust::device_vector<Eigen::Vector3f_u>::iterator> IteratorTuple;
        typedef thrust::zip_iterator<IteratorTuple> ZipIterator;
        auto n_out = CalcAverageByKey<ZipIterator, Eigen::Vector3f_u, Eigen::Vector3f_u>(keys,
                    thrust::make_zip_iterator(thrust::make_tuple(sorted_points.begin(), sorted_colors.begin())),
                    thrust::make_zip_iterator(thrust::make_tuple(output->points_.begin(), output->colors_.begin())));
        output->points_.resize(n_out);
        output->colors_.resize(n_out);
    } else {
        thrust::device_vector<Eigen::Vector3f_u> sorted_normals = normals_;
        thrust::device_vector<Eigen::Vector3f_u> sorted_colors = colors_;
        output->normals_.resize(n);
        output->colors_.resize(n);
        typedef thrust::tuple<thrust::device_vector<Eigen::Vector3f_u>::iterator, thrust::device_vector<Eigen::Vector3f_u>::iterator, thrust::device_vector<Eigen::Vector3f_u>::iterator> IteratorTuple;
        typedef thrust::zip_iterator<IteratorTuple> ZipIterator;
        auto n_out = CalcAverageByKey<ZipIterator, Eigen::Vector3f_u, Eigen::Vector3f_u, Eigen::Vector3f_u>(keys,
                    thrust::make_zip_iterator(thrust::make_tuple(sorted_points.begin(), sorted_normals.begin(), sorted_colors.begin())),
                    thrust::make_zip_iterator(thrust::make_tuple(output->points_.begin(), output->normals_.begin(), output->colors_.begin())));
        output->points_.resize(n_out);
        output->normals_.resize(n_out);
        output->colors_.resize(n_out);
        thrust::for_each(output->normals_.begin(), output->normals_.end(), [] __device__ (Eigen::Vector3f_u& nl) {nl.normalize();});
    }

    utility::LogDebug(
            "Pointcloud down sampled from {:d} points to {:d} points.\n",
            (int)points_.size(), (int)output->points_.size());
    return output;
}

std::shared_ptr<PointCloud> PointCloud::UniformDownSample(
    size_t every_k_points) const {
    auto output = std::make_shared<PointCloud>();
    if (every_k_points == 0) {
        utility::LogError("[UniformDownSample] Illegal sample rate.");
        return output;
    }
    const int n_out = points_.size() / every_k_points;
    output->points_.resize(n_out);
    thrust::transform(thrust::make_constant_iterator(0), thrust::make_constant_iterator(n_out),
                      output->points_.begin(), stride_copy_functor(thrust::raw_pointer_cast(output->points_.data()), every_k_points));
    if (HasNormals()) {
        output->normals_.resize(n_out);
        thrust::transform(thrust::make_constant_iterator(0), thrust::make_constant_iterator(n_out),
                          output->normals_.begin(), stride_copy_functor(thrust::raw_pointer_cast(output->normals_.data()), every_k_points));
    }
    if (HasColors()) {
        output->normals_.resize(n_out);
        thrust::transform(thrust::make_constant_iterator(0), thrust::make_constant_iterator(n_out),
                          output->colors_.begin(), stride_copy_functor(thrust::raw_pointer_cast(output->colors_.data()), every_k_points));
    }
    return output;
}

std::tuple<std::shared_ptr<PointCloud>, thrust::device_vector<size_t>>
PointCloud::RemoveRadiusOutliers(size_t nb_points, float search_radius) const {
    if (nb_points < 1 || search_radius <= 0) {
        utility::LogError(
                "[RemoveRadiusOutliers] Illegal input parameters,"
                "number of points and radius must be positive");
    }
    KDTreeFlann kdtree;
    kdtree.SetGeometry(*this);
    thrust::device_vector<int> tmp_indices;
    thrust::device_vector<float> dist;
    kdtree.SearchRadius(points_, search_radius, tmp_indices, dist);
    const size_t n_pt = points_.size();
    thrust::device_vector<size_t> indices(n_pt);
    has_radius_points_functor func(thrust::raw_pointer_cast(tmp_indices.data()), nb_points);
    auto end = thrust::transform(thrust::make_counting_iterator<size_t>(0), thrust::make_counting_iterator(n_pt),
                                 indices.begin(), func);
    indices.resize(thrust::distance(indices.begin(), end));
    return std::make_tuple(SelectDownSample(indices), indices);
}

std::tuple<std::shared_ptr<PointCloud>, thrust::device_vector<size_t>>
PointCloud::RemoveStatisticalOutliers(size_t nb_neighbors,
                                      float std_ratio) const {
    if (nb_neighbors < 1 || std_ratio <= 0) {
        utility::LogError(
                "[RemoveStatisticalOutliers] Illegal input parameters, number "
                "of neighbors and standard deviation ratio must be positive");
    }
    if (points_.empty()) {
        return std::make_tuple(std::make_shared<PointCloud>(),
                               thrust::device_vector<size_t>());
    }
    KDTreeFlann kdtree;
    kdtree.SetGeometry(*this);
    const int n_pt = points_.size();
    thrust::device_vector<float> avg_distances(n_pt);
    thrust::device_vector<size_t> indices(n_pt);
    thrust::device_vector<int> tmp_indices;
    thrust::device_vector<float> dist;
    kdtree.SearchKNN(points_, int(nb_neighbors), tmp_indices, dist);
    average_distance_functor avg_func(thrust::raw_pointer_cast(dist.data()));
    thrust::transform(thrust::make_counting_iterator<size_t>(0), thrust::make_counting_iterator((size_t)n_pt),
                      avg_distances.begin(), avg_func);
    const size_t valid_distances = thrust::count_if(avg_distances.begin(), avg_distances.end(), [] __device__ (float x) {return (x >= 0.0);});
    if (valid_distances == 0) {
        return std::make_tuple(std::make_shared<PointCloud>(),
                               thrust::device_vector<size_t>());
    }
    float cloud_mean = thrust::reduce(avg_distances.begin(), avg_distances.end(), 0.0,
            [] __device__ (float const &x, float const &y) { return (y > 0) ? x + y : x; });
    cloud_mean /= valid_distances;
    const float sq_sum = thrust::inner_product(
            avg_distances.begin(), avg_distances.end(), avg_distances.begin(),
            0.0, [] __device__ (float const &x, float const &y) { return x + y; },
            [cloud_mean] __device__ (float const &x, float const &y) {
                return x > 0 ? (x - cloud_mean) * (y - cloud_mean) : 0;
            });
    // Bessel's correction
    const float std_dev = std::sqrt(sq_sum / (valid_distances - 1));
    const float distance_threshold = cloud_mean + std_ratio * std_dev;
    check_distance_threshold_functor th_func(thrust::raw_pointer_cast(avg_distances.data()), distance_threshold);
    auto end = thrust::copy_if(thrust::make_counting_iterator<size_t>(0), thrust::make_counting_iterator((size_t)n_pt),
                               indices.begin(), th_func);
    indices.resize(thrust::distance(indices.begin(), end));
    return std::make_tuple(SelectDownSample(indices), indices);
}