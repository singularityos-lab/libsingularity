#include <string.h>
#include <time.h>

#include <gio/gio.h>
#include <gnutls/gnutls.h>
#include <gnutls/x509.h>

gboolean
singularity_live_tls_generate (gchar **cert_pem, gchar **key_pem, GError **error)
{
    gnutls_x509_privkey_t key = NULL;
    gnutls_x509_crt_t crt = NULL;
    gnutls_datum_t kd = { 0 };
    gnutls_datum_t cd = { 0 };
    guint8 serial[16];
    const gchar *name = "singularity-live";
    gboolean ok = FALSE;
    gint ret;
    time_t now = time (NULL);

    *cert_pem = NULL;
    *key_pem = NULL;
    if ((ret = gnutls_x509_privkey_init (&key)) < 0 ||
        (ret = gnutls_x509_privkey_generate (key, GNUTLS_PK_ECDSA,
                                             GNUTLS_CURVE_TO_BITS (GNUTLS_ECC_CURVE_SECP256R1), 0)) < 0 ||
        (ret = gnutls_x509_crt_init (&crt)) < 0)
        goto out;

    for (guint i = 0; i < sizeof (serial); i++)
        serial[i] = (guint8) g_random_int_range (0, 256);
    serial[0] &= 0x7f;

    if ((ret = gnutls_x509_crt_set_version (crt, 3)) < 0 ||
        (ret = gnutls_x509_crt_set_serial (crt, serial, sizeof (serial))) < 0 ||
        (ret = gnutls_x509_crt_set_activation_time (crt, now - 24 * 3600)) < 0 ||
        (ret = gnutls_x509_crt_set_expiration_time (crt, now + (time_t) 30 * 24 * 3600)) < 0 ||
        (ret = gnutls_x509_crt_set_dn_by_oid (crt, GNUTLS_OID_X520_COMMON_NAME, 0, name, (unsigned) strlen (name))) < 0 ||
        (ret = gnutls_x509_crt_set_key (crt, key)) < 0 ||
        (ret = gnutls_x509_crt_set_basic_constraints (crt, 0, -1)) < 0 ||
        (ret = gnutls_x509_crt_set_key_usage (crt, GNUTLS_KEY_DIGITAL_SIGNATURE)) < 0 ||
        (ret = gnutls_x509_crt_set_key_purpose_oid (crt, GNUTLS_KP_TLS_WWW_SERVER, 0)) < 0 ||
        (ret = gnutls_x509_crt_sign2 (crt, crt, key, GNUTLS_DIG_SHA256, 0)) < 0 ||
        (ret = gnutls_x509_privkey_export2 (key, GNUTLS_X509_FMT_PEM, &kd)) < 0 ||
        (ret = gnutls_x509_crt_export2 (crt, GNUTLS_X509_FMT_PEM, &cd)) < 0)
        goto out;

    *key_pem = g_strndup ((const gchar *) kd.data, kd.size);
    *cert_pem = g_strndup ((const gchar *) cd.data, cd.size);
    ok = TRUE;

out:
    if (ret < 0)
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Cannot create the session certificate: %s",
                     gnutls_strerror (ret));
    gnutls_free (kd.data);
    gnutls_free (cd.data);
    if (crt != NULL)
        gnutls_x509_crt_deinit (crt);
    if (key != NULL)
        gnutls_x509_privkey_deinit (key);
    return ok;
}
