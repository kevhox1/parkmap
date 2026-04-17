window.WEPARK_TRACKER_CONFIG = {
  // Default stays on the local mock provider so the app works with zero backend setup.
  provider: 'mock',

  // Fill these in and switch provider to 'supabase' when ready.
  supabaseUrl: '',
  supabaseAnonKey: '',

  // If Supabase init fails, the UI falls back to the local mock provider.
  allowMockFallback: true,

  supabase: {
    // Supported now:
    // - 'none'      => read-only Supabase wiring, write gate explains config is missing
    // - 'anonymous' => auth gate tries Supabase anonymous sign-in for write actions
    authMode: 'none',

    // Optional realtime refresh hook. Safe to leave off until DB subscriptions are ready.
    realtime: false
  }
};
