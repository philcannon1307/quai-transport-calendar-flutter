import { createApp } from "./app.js";
import { loadConfig } from "./config.js";

const { config, errors, warnings } = loadConfig(process.env);
const log = (event, fields = {}) => console.log(JSON.stringify({ t: new Date().toISOString(), event, ...fields }));

for (const w of warnings) log("config_warning", { message: w });
if (errors.length) {
  for (const e of errors) log("config_error", { message: e });
  console.error("Refusing to start: fix the configuration above (see README / .env.example).");
  process.exit(1);
}

let store = null;
if (config.data.store === "postgres") {
  const { default: pg } = await import("pg");
  const { PgStore } = await import("./data/store-pg.js");
  const pool = new pg.Pool({ connectionString: config.data.databaseUrl, max: 5, ssl: /sslmode=disable/.test(config.data.databaseUrl) || /@(localhost|127\.0\.0\.1|[a-z0-9-]+\.railway\.internal)/.test(config.data.databaseUrl) ? undefined : { rejectUnauthorized: false } });
  pool.on("error", (e) => log("db_pool_error", { message: e.message }));
  store = new PgStore(pool);
} else if (config.data.store === "memory") {
  const { MemoryStore } = await import("./data/store-memory.js");
  store = new MemoryStore();
  log("config_warning", { message: "DATA_STORE=memory: data is lost on restart (development only)." });
}
const { createProvider } = await import("./data/email.js");
const mailer = createProvider(config.data.email);

const server = createApp(config, { log, store, mailer });
server.listen(config.port, "0.0.0.0", () => log("listening", { port: config.port, origins: [...config.allowedOrigins] }));

for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => server.close(() => process.exit(0)));
