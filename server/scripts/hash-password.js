// Usage: npm run hash-password   (you are asked for the password; nothing is stored)
import { createInterface } from "node:readline";
import { hashPassword } from "../src/config.js";

const rl = createInterface({ input: process.stdin, output: process.stderr, terminal: false });
process.stderr.write("Type the SuperUser password, then press Enter: ");
rl.once("line", (line) => {
  if (!line) { console.error("Empty password."); process.exit(1); }
  console.log(hashPassword(line));
  rl.close();
});
