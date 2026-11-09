#ifndef SINGULARITY_BACKGROUND_WORK_H
#define SINGULARITY_BACKGROUND_WORK_H

#include <glib.h>

int singularity_background_current_tid(void);
int singularity_background_nice_of(int tid);
void singularity_background_lower_self(void);
gboolean singularity_background_apply(int id, gboolean thread, gboolean background, int normal_nice);

#endif
