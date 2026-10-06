#ifndef SINGULARITY_SNAP_BUTTON_H
#define SINGULARITY_SNAP_BUTTON_H

#include <gtk/gtk.h>

gboolean singularity_snap_button_available(GtkWidget *widget);
void singularity_snap_button_enter(GtkWidget *widget);
void singularity_snap_button_leave(GtkWidget *widget);

#endif
