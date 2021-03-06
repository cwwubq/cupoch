#include "cupoch/camera/pinhole_camera_intrinsic.h"
#include "cupoch/camera/pinhole_camera_parameters.h"

#include "cupoch_pybind/camera/camera.h"
#include "cupoch_pybind/docstring.h"

using namespace cupoch;

void pybind_camera_classes(py::module &m) {
    // cupoch.camera.PinholeCameraIntrinsic
    py::class_<camera::PinholeCameraIntrinsic> pinhole_intr(
            m, "PinholeCameraIntrinsic",
            "PinholeCameraIntrinsic class stores intrinsic camera matrix, and "
            "image height and width.");
    py::detail::bind_default_constructor<camera::PinholeCameraIntrinsic>(
            pinhole_intr);
    py::detail::bind_copy_functions<camera::PinholeCameraIntrinsic>(
            pinhole_intr);
    pinhole_intr
            .def(py::init([](int w, int h, double fx, double fy, double cx,
                             double cy) {
                     return new camera::PinholeCameraIntrinsic(w, h, fx, fy, cx,
                                                               cy);
                 }),
                 "width"_a, "height"_a, "fx"_a, "fy"_a, "cx"_a, "cy"_a)
            .def(py::init([](camera::PinholeCameraIntrinsicParameters param) {
                     return new camera::PinholeCameraIntrinsic(param);
                 }),
                 "param"_a);
    pinhole_intr
            .def("set_intrinsics",
                 &camera::PinholeCameraIntrinsic::SetIntrinsics, "width"_a,
                 "height"_a, "fx"_a, "fy"_a, "cx"_a, "cy"_a,
                 "Set camera intrinsic parameters.")
            .def("get_focal_length",
                 &camera::PinholeCameraIntrinsic::GetFocalLength,
                 "Returns the focal length in a tuple of X-axis and Y-axis"
                 "focal lengths.")
            .def("get_principal_point",
                 &camera::PinholeCameraIntrinsic::GetPrincipalPoint,
                 "Returns the principle point in a tuple of X-axis and."
                 "Y-axis principle points")
            .def("get_skew", &camera::PinholeCameraIntrinsic::GetSkew,
                 "Returns the skew.")
            .def("is_valid", &camera::PinholeCameraIntrinsic::IsValid,
                 "Returns True iff both the width and height are greater than "
                 "0.")
            .def_readwrite("width", &camera::PinholeCameraIntrinsic::width_,
                           "int: Width of the image.")
            .def_readwrite("height", &camera::PinholeCameraIntrinsic::height_,
                           "int: Height of the image.")
            .def_readwrite("intrinsic_matrix",
                           &camera::PinholeCameraIntrinsic::intrinsic_matrix_,
                           "3x3 numpy array: Intrinsic camera matrix ``[[fx, "
                           "0, cx], [0, fy, "
                           "cy], [0, 0, 1]]``")
            .def("__repr__", [](const camera::PinholeCameraIntrinsic &c) {
                return std::string(
                               "camera::PinholeCameraIntrinsic with width = ") +
                       std::to_string(c.width_) +
                       std::string(" and height = ") +
                       std::to_string(c.height_) +
                       std::string(
                               ".\nAccess intrinsics with intrinsic_matrix.");
            });
    docstring::ClassMethodDocInject(m, "PinholeCameraIntrinsic", "__init__");
    docstring::ClassMethodDocInject(m, "PinholeCameraIntrinsic",
                                    "set_intrinsics",
                                    {{"width", "Width of the image."},
                                     {"height", "Height of the image."},
                                     {"fx", "X-axis focal length"},
                                     {"fy", "Y-axis focal length."},
                                     {"cx", "X-axis principle point."},
                                     {"cy", "Y-axis principle point."}});
    docstring::ClassMethodDocInject(m, "PinholeCameraIntrinsic",
                                    "get_focal_length");
    docstring::ClassMethodDocInject(m, "PinholeCameraIntrinsic",
                                    "get_principal_point");
    docstring::ClassMethodDocInject(m, "PinholeCameraIntrinsic", "get_skew");
    docstring::ClassMethodDocInject(m, "PinholeCameraIntrinsic", "is_valid");

    // cupoch.camera.PinholeCameraIntrinsicParameters
    py::enum_<camera::PinholeCameraIntrinsicParameters> pinhole_intr_params(
            m, "PinholeCameraIntrinsicParameters", py::arithmetic(),
            "PinholeCameraIntrinsicParameters");
    pinhole_intr_params
            .value("PrimeSenseDefault",
                   camera::PinholeCameraIntrinsicParameters::PrimeSenseDefault,
                   "Default camera intrinsic parameter for PrimeSense.")
            .value("Kinect2DepthCameraDefault",
                   camera::PinholeCameraIntrinsicParameters::
                           Kinect2DepthCameraDefault,
                   "Default camera intrinsic parameter for Kinect2 depth "
                   "camera.")
            .value("Kinect2ColorCameraDefault",
                   camera::PinholeCameraIntrinsicParameters::
                           Kinect2ColorCameraDefault,
                   "Default camera intrinsic parameter for Kinect2 color "
                   "camera.")
            .export_values();
    pinhole_intr_params.attr("__doc__") = docstring::static_property(
            py::cpp_function([](py::handle arg) -> std::string {
                return "Enum class that contains default camera intrinsic "
                       "parameters for different sensors.";
            }),
            py::none(), py::none(), "");

    // cupoch.camera.PinholeCameraParameters
    py::class_<camera::PinholeCameraParameters> pinhole_param(
            m, "PinholeCameraParameters",
            "Contains both intrinsic and extrinsic pinhole camera parameters.");
    py::detail::bind_default_constructor<camera::PinholeCameraParameters>(
            pinhole_param);
    py::detail::bind_copy_functions<camera::PinholeCameraParameters>(
            pinhole_param);
    pinhole_param
            .def_readwrite("intrinsic",
                           &camera::PinholeCameraParameters::intrinsic_,
                           "``cupoch.camera.PinholeCameraIntrinsic``: "
                           "PinholeCameraIntrinsic "
                           "object.")
            .def_readwrite("extrinsic",
                           &camera::PinholeCameraParameters::extrinsic_,
                           "4x4 numpy array: Camera extrinsic parameters.")
            .def("__repr__", [](const camera::PinholeCameraParameters &c) {
                return std::string("camera::PinholeCameraParameters class.\n") +
                       std::string(
                               "Access its data via intrinsic and extrinsic.");
            });
}

void pybind_camera(py::module &m) {
    py::module m_submodule = m.def_submodule("camera");
    pybind_camera_classes(m_submodule);
}