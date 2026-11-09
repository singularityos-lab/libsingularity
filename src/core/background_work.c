#include "background_work.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#define IOPRIO_WHO_PROCESS 1
#define IOPRIO_CLASS_SHIFT 13
#define IOPRIO_CLASS_IDLE 3
#define BACKGROUND_NICE 19
#define MAX_DEPTH 8

int
singularity_background_current_tid(void)
{
	return (int) syscall(SYS_gettid);
}

int
singularity_background_nice_of(int tid)
{
	errno = 0;
	int value = getpriority(PRIO_PROCESS, (id_t) tid);
	return errno != 0 ? 0 : value;
}

static gboolean
set_io(int tid, gboolean background)
{
#ifdef SYS_ioprio_set
	int value = background ? IOPRIO_CLASS_IDLE << IOPRIO_CLASS_SHIFT : 0;
	return syscall(SYS_ioprio_set, IOPRIO_WHO_PROCESS, tid, value) == 0;
#else
	return FALSE;
#endif
}

static void
allow_raise(int nice_value)
{
	struct rlimit limit;

	if (getrlimit(RLIMIT_NICE, &limit) != 0)
		return;
	rlim_t wanted = (rlim_t) (20 - nice_value);
	if (limit.rlim_cur >= wanted)
		return;
	limit.rlim_cur = limit.rlim_max == RLIM_INFINITY || limit.rlim_max >= wanted ? wanted : limit.rlim_max;
	setrlimit(RLIMIT_NICE, &limit);
}

static gboolean
set_cpu(int tid, int nice_value)
{
	if (setpriority(PRIO_PROCESS, (id_t) tid, nice_value) == 0)
		return TRUE;
	if (errno != EPERM && errno != EACCES)
		return FALSE;
	allow_raise(nice_value);
	return setpriority(PRIO_PROCESS, (id_t) tid, nice_value) == 0;
}

static gboolean
apply_task(int tid, gboolean background, int normal_nice)
{
	gboolean cpu = set_cpu(tid, background ? BACKGROUND_NICE : normal_nice);
	gboolean io = set_io(tid, background);
	return cpu && io;
}

void
singularity_background_lower_self(void)
{
#ifdef SYS_ioprio_set
	syscall(SYS_ioprio_set, IOPRIO_WHO_PROCESS, 0, IOPRIO_CLASS_IDLE << IOPRIO_CLASS_SHIFT);
#endif
	setpriority(PRIO_PROCESS, 0, BACKGROUND_NICE);
}

static gboolean apply_tree(int pid, gboolean background, int normal_nice, int depth);

static gboolean
apply_children(const char *task_dir, gboolean background, int normal_nice, int depth)
{
	char path[256];
	gboolean ok = TRUE;

	snprintf(path, sizeof path, "%s/children", task_dir);
	FILE *file = fopen(path, "r");
	if (file == NULL)
		return TRUE;
	int child;
	while (fscanf(file, "%d", &child) == 1) {
		ok = apply_tree(child, background, normal_nice, depth + 1) && ok;
	}
	fclose(file);
	return ok;
}

static gboolean
apply_tree(int pid, gboolean background, int normal_nice, int depth)
{
	char dir_path[64];
	gboolean ok = TRUE;
	gboolean any = FALSE;

	if (depth > MAX_DEPTH)
		return TRUE;
	snprintf(dir_path, sizeof dir_path, "/proc/%d/task", pid);
	DIR *dir = opendir(dir_path);
	if (dir == NULL)
		return apply_task(pid, background, normal_nice);
	struct dirent *entry;
	while ((entry = readdir(dir)) != NULL) {
		if (entry->d_name[0] < '0' || entry->d_name[0] > '9')
			continue;
		int tid = atoi(entry->d_name);
		char task_dir[128];
		snprintf(task_dir, sizeof task_dir, "%s/%d", dir_path, tid);
		ok = apply_task(tid, background, normal_nice) && ok;
		ok = apply_children(task_dir, background, normal_nice, depth) && ok;
		any = TRUE;
	}
	closedir(dir);
	return any && ok;
}

gboolean
singularity_background_apply(int id, gboolean thread, gboolean background, int normal_nice)
{
	if (thread)
		return apply_task(id, background, normal_nice);
	return apply_tree(id, background, normal_nice, 0);
}
