export const tasksKeys = {
  all: (projectId: string) => ['tasks', projectId] as const,
  byProject: (projectId: string) => [...tasksKeys.all(projectId), 'list'] as const,
}
