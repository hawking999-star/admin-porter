import { useCallback } from "react";
import { useSearchParams } from "react-router-dom";

/** Vários filtros devem mudar em uma única navegação. null remove a chave. */
export function useUrlFilterPatch() {
  const [, setSearchParams] = useSearchParams();
  return useCallback((patch: Record<string, string | null>) => {
    setSearchParams((current) => {
      const next = new URLSearchParams(current);
      for (const [key, value] of Object.entries(patch)) {
        if (value === null || value === "") next.delete(key);
        else next.set(key, value);
      }
      return next;
    }, { replace: true });
  }, [setSearchParams]);
}

export function useUrlFilterState<T extends string = string>(
  key: string,
  fallback: NoInfer<T>,
  allowed?: readonly T[],
): [T, (value: T) => void] {
  const [searchParams, setSearchParams] = useSearchParams();
  const raw = searchParams.get(key);
  const value = raw && (!allowed || allowed.includes(raw as T)) ? raw as T : fallback;

  const setValue = useCallback((nextValue: T) => {
    setSearchParams((current) => {
      const next = new URLSearchParams(current);
      if (!nextValue || nextValue === fallback) next.delete(key);
      else next.set(key, nextValue);
      return next;
    }, { replace: true });
  }, [fallback, key, setSearchParams]);

  return [value, setValue];
}
