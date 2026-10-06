[CCode (cheader_filename = "lcms2.h")]
namespace Lcms {
    [CCode (cname = "cmsCIExyY", has_type_id = false)]
    public struct CIExyY {
        public double x;
        public double y;
        public double Y;
    }

    [CCode (cname = "cmsCIExyYTRIPLE", has_type_id = false)]
    public struct CIExyYTriple {
        public CIExyY Red;
        public CIExyY Green;
        public CIExyY Blue;
    }

    [CCode (cname = "TYPE_RGBA_FLT")]
    public const uint32 TYPE_RGBA_FLT;
    [CCode (cname = "TYPE_RGBA_8")]
    public const uint32 TYPE_RGBA_8;
    [CCode (cname = "TYPE_RGBA_16")]
    public const uint32 TYPE_RGBA_16;
    [CCode (cname = "TYPE_RGB_8")]
    public const uint32 TYPE_RGB_8;

    [CCode (cname = "cmsFLAGS_NOCACHE")]
    public const uint32 FLAGS_NOCACHE;
    [CCode (cname = "cmsFLAGS_GAMUTCHECK")]
    public const uint32 FLAGS_GAMUTCHECK;
    [CCode (cname = "cmsFLAGS_SOFTPROOFING")]
    public const uint32 FLAGS_SOFTPROOFING;
    [CCode (cname = "cmsFLAGS_BLACKPOINTCOMPENSATION")]
    public const uint32 FLAGS_BLACKPOINTCOMPENSATION;
    [CCode (cname = "cmsFLAGS_COPY_ALPHA")]
    public const uint32 FLAGS_COPY_ALPHA;

    [CCode (cname = "cmsCreate_sRGBProfile")]
    public void* create_srgb_profile();
    [CCode (cname = "cmsCreateRGBProfile")]
    public void* create_rgb_profile(CIExyY white, CIExyYTriple primaries, [CCode (array_length = false)] void*[] curves);
    [CCode (cname = "cmsCreateGrayProfile")]
    public void* create_gray_profile(CIExyY white, void* curve);
    [CCode (cname = "cmsCreateLab4Profile")]
    public void* create_lab4_profile(void* white);
    [CCode (cname = "cmsBuildGamma")]
    public void* build_gamma(void* context, double gamma);
    [CCode (cname = "cmsBuildParametricToneCurve")]
    public void* build_parametric_tone_curve(void* context, int type, [CCode (array_length = false)] double[] parameters);
    [CCode (cname = "cmsFreeToneCurve")]
    public void free_tone_curve(void* curve);
    [CCode (cname = "cmsOpenProfileFromMem")]
    public void* open_profile_from_mem([CCode (array_length_type = "cmsUInt32Number")] uint8[] data);
    [CCode (cname = "cmsOpenProfileFromFile")]
    public void* open_profile_from_file(string path, string mode);
    [CCode (cname = "cmsSaveProfileToMem")]
    public bool save_profile_to_mem(void* profile, void* mem, ref uint32 bytes_needed);
    [CCode (cname = "cmsCloseProfile")]
    public bool close_profile(void* profile);
    [CCode (cname = "cmsGetProfileInfoASCII")]
    public uint32 get_profile_info_ascii(void* profile, int info, string language, string country, [CCode (array_length_type = "cmsUInt32Number")] uint8[] buffer);
    [CCode (cname = "cmsGetColorSpace")]
    public uint32 get_color_space(void* profile);
    [CCode (cname = "cmsCreateTransform")]
    public void* create_transform(void* input, uint32 input_format, void* output, uint32 output_format, uint32 intent, uint32 flags);
    [CCode (cname = "cmsCreateProofingTransform")]
    public void* create_proofing_transform(void* input, uint32 input_format, void* output, uint32 output_format, void* proofing, uint32 intent, uint32 proofing_intent, uint32 flags);
    [CCode (cname = "cmsDoTransform")]
    public void do_transform(void* transform, void* input, void* output, uint32 size);
    [CCode (cname = "cmsDeleteTransform")]
    public void delete_transform(void* transform);
    [CCode (cname = "cmsSetAlarmCodes")]
    public void set_alarm_codes([CCode (array_length = false)] uint16[] codes);
    [CCode (cname = "cmsWhitePointFromTemp")]
    public bool white_point_from_temp(out CIExyY white, double temperature);
}
