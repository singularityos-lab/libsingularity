#include "rd_tls.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <gio/gio.h>
#include <gnutls/gnutls.h>
#include <gnutls/x509.h>

static gboolean
write_datum (const gchar *path, gnutls_datum_t *datum, gint mode, GError **error)
{
    gchar *tmp = g_strconcat (path, ".tmp", NULL);
    gint fd = open (tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    gboolean ok = fd >= 0 && write (fd, datum->data, datum->size) == (gssize) datum->size;
    if (fd >= 0)
        close (fd);
    if (ok)
        ok = rename (tmp, path) == 0;
    if (!ok) {
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "Cannot write %s: %s", path,
                     g_strerror (errno));
        unlink (tmp);
    }
    g_free (tmp);
    return ok;
}

gboolean
rd_tls_generate (const gchar *cert_path, const gchar *key_path, const gchar *common_name, GError **error)
{
    gnutls_x509_privkey_t key = NULL;
    gnutls_x509_crt_t crt = NULL;
    gnutls_datum_t key_pem = { 0 };
    gnutls_datum_t crt_pem = { 0 };
    guint8 serial[16];
    gboolean ok = FALSE;
    gint ret;
    time_t now = time (NULL);

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
        (ret = gnutls_x509_crt_set_expiration_time (crt, now + (time_t) 10 * 365 * 24 * 3600)) < 0 ||
        (ret = gnutls_x509_crt_set_dn_by_oid (crt, GNUTLS_OID_X520_COMMON_NAME, 0, common_name,
                                              (unsigned) strlen (common_name))) < 0 ||
        (ret = gnutls_x509_crt_set_key (crt, key)) < 0 ||
        (ret = gnutls_x509_crt_set_basic_constraints (crt, 0, -1)) < 0 ||
        (ret = gnutls_x509_crt_set_key_usage (crt, GNUTLS_KEY_DIGITAL_SIGNATURE)) < 0 ||
        (ret = gnutls_x509_crt_set_key_purpose_oid (crt, GNUTLS_KP_TLS_WWW_SERVER, 0)) < 0 ||
        (ret = gnutls_x509_crt_set_subject_alt_name (crt, GNUTLS_SAN_DNSNAME, common_name,
                                                     (unsigned) strlen (common_name), GNUTLS_FSAN_SET)) < 0 ||
        (ret = gnutls_x509_crt_sign2 (crt, crt, key, GNUTLS_DIG_SHA256, 0)) < 0 ||
        (ret = gnutls_x509_privkey_export2 (key, GNUTLS_X509_FMT_PEM, &key_pem)) < 0 ||
        (ret = gnutls_x509_crt_export2 (crt, GNUTLS_X509_FMT_PEM, &crt_pem)) < 0)
        goto out;

    ok = write_datum (key_path, &key_pem, 0600, error) && write_datum (cert_path, &crt_pem, 0644, error);
    ret = 0;

out:
    if (ret < 0)
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Cannot create the certificate: %s",
                     gnutls_strerror (ret));
    gnutls_free (key_pem.data);
    gnutls_free (crt_pem.data);
    if (crt != NULL)
        gnutls_x509_crt_deinit (crt);
    if (key != NULL)
        gnutls_x509_privkey_deinit (key);
    return ok;
}
