import path from "path";
import dotenv from "dotenv";

dotenv.config();

function parseRequiredNumber(name: string, value: string | undefined): number {
  if (!value) {
    throw new Error(`${name} is required`);
  }

  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    throw new Error(`${name} must be a valid number`);
  }

  return parsed;
}

const projectRoot = process.cwd();

export const config = {
  telegramApiId: parseRequiredNumber("TELEGRAM_API_ID", process.env.TELEGRAM_API_ID),
  telegramApiHash: process.env.TELEGRAM_API_HASH,
  telegramStringSession: process.env.TELEGRAM_STRING_SESSION,
  telegramSessionFilePath:
    process.env.TELEGRAM_SESSION_FILE_PATH ??
    path.join(projectRoot, "data", "telegram.session"),
  telegramPhoneNumber: process.env.TELEGRAM_PHONE_NUMBER,
  telegramLoginCode: process.env.TELEGRAM_LOGIN_CODE,
  telegramPassword: process.env.TELEGRAM_PASSWORD,
  targetGroupName: process.env.TARGET_GROUP_NAME ?? "FXD Trades | VIP",
  dataFilePath:
    process.env.DATA_FILE_PATH ?? path.join(projectRoot, "data", "messages.jsonl"),
  signalConsumedStatePath:
    process.env.SIGNAL_CONSUMED_STATE_PATH ??
    path.join(projectRoot, "data", "signalConsumption.json"),
  apiPort: Number(process.env.API_PORT ?? 8787)
};

if (!config.telegramApiHash) {
  throw new Error("TELEGRAM_API_HASH is required");
}
