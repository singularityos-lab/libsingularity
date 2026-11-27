namespace Singularity.Imaging {

    public Gdk.Texture backdrop(Gdk.Texture source, int shown_width, double blur_radius, double saturation = 1.0) {
        var img = FloatImage.from_texture(source, false).scaled_to_fit(256);
        bool opaque = img.is_opaque();
        size_t n = img.pixel_count();
        if (!opaque) {
            for (size_t i = 0; i < n; i++) {
                float a = img.data[i * 4 + 3];
                for (int c = 0; c < 3; c++) img.data[i * 4 + c] *= a;
            }
        }
        double sigma = blur_radius * 0.5 * img.width / double.max(1.0, shown_width);
        img = Filters.gaussian(img, sigma, !opaque);
        float sat = (float) saturation;
        for (size_t i = 0; i < n; i++) {
            float a = img.data[i * 4 + 3];
            float r = img.data[i * 4], g = img.data[i * 4 + 1], b = img.data[i * 4 + 2];
            if (!opaque) {
                float inv = a > 0.0f ? 1.0f / a : 0.0f;
                r *= inv;
                g *= inv;
                b *= inv;
            }
            float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            img.data[i * 4] = (l + (r - l) * sat).clamp(0.0f, 1.0f);
            img.data[i * 4 + 1] = (l + (g - l) * sat).clamp(0.0f, 1.0f);
            img.data[i * 4 + 2] = (l + (b - l) * sat).clamp(0.0f, 1.0f);
        }
        return img.to_texture(false);
    }
}
