export async function apiFetch(url: string, options: RequestInit = {}): Promise<Response> {
  const res = await fetch(url, options);
  if (res.status === 401) {
    window.location.replace('/login');
    return new Promise(() => {});
  }
  return res;
}
