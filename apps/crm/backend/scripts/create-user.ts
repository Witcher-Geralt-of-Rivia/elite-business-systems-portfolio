/**
 * Creates a CRM user + team member (sales row).
 *   node --env-file=.env scripts/create-user.ts --email a@example.com --first Ada --last Byron --role admin
 * The password is read from the CRM_NEW_USER_PASSWORD environment variable (never from argv, which
 * is visible in process listings).
 */
import { parseArgs } from "node:util";
import { hashPassword, validatePasswordStrength } from "../src/auth/password.ts";
import { createPool, withTransaction } from "../src/db.ts";

const { values } = parseArgs({
  options: {
    email: { type: "string" },
    first: { type: "string" },
    last: { type: "string" },
    role: { type: "string", default: "sales_rep" },
  },
});
const password = process.env.CRM_NEW_USER_PASSWORD;
const problem = validatePasswordStrength(password);
if (!values.email || !values.first || !values.last) throw new Error("--email, --first and --last are required");
if (problem) throw new Error(problem);
if (!["admin", "manager", "sales_rep", "showcase"].includes(values.role!)) throw new Error("invalid --role");

const db = createPool(process.env.CRM_DATABASE_URL!, 1);
try {
  const salesId = await withTransaction(db, async (c) => {
    const { rows } = await c.query(`insert into users (email, password_hash) values ($1, $2) returning id`, [
      values.email,
      await hashPassword(password!),
    ]);
    const sale = await c.query(
      `insert into sales (first_name, last_name, email, role, user_id) values ($1, $2, $3, $4, $5) returning id`,
      [values.first, values.last, values.email, values.role, rows[0].id],
    );
    return sale.rows[0].id;
  });
  console.log(`created ${values.role} ${values.email} (sales id ${salesId})`);
} finally {
  await db.end();
}
