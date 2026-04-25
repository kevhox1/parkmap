window.WEPARK_TRACKER_CONFIG = {
  // Tracker provider: keep 'mock' until the SUPABASE_MVP_SCHEMA.md tables/RPCs
  // are applied to the project. Auth + chat use the same URL/key independently.
  provider: 'mock',

  // Live Supabase project (created 2026-04-22). Publishable key is safe to ship
  // client-side; RLS policies guard the actual data.
  supabaseUrl: 'https://jiispshyqerscdoferaw.supabase.co',
  supabaseAnonKey: 'sb_publishable_SEIuWH-HscK3X7wtbLMCqw_ZjRCevRR',

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
