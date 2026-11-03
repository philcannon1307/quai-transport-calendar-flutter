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

const server = createApp(config, { log });
server.listen(config.port, "0.0.0.0", () => log("listening", { port: config.port, origins: [...config.allowedOrigins] }));

for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => server.close(() => process.exit(0)));
