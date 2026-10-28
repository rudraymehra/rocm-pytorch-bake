# Installed as torch/_rocm_init.py; torch/__init__.py calls initialize() on import.
# Preloads the ROCm libraries of TheRock's pip packages, so that libraries loaded
# after torch (for example LMCache's CuPy) find them too. The list is the one in
# AMD's torch 2.13.0+rocm10.0.0 wheel; @ROCM_SDK_VERSION@ is set at build time.


def initialize():
    import rocm_sdk
    rocm_sdk.initialize_process(
        preload_shortnames=['amd_comgr', 'amdhip64', 'rocprofiler-sdk', 'rocprofiler-sdk-roctx', 'roctracer64', 'roctx64', 'hiprtc', 'hipblas', 'hipfft', 'hiprand', 'hipsparse', 'hipsparselt', 'hipsolver', 'rccl', 'hipblaslt', 'miopen', 'hipdnn', 'rocm_sysdeps_liblzma', 'rocm-openblas', 'rocm_smi64'],
        check_version='@ROCM_SDK_VERSION@')
