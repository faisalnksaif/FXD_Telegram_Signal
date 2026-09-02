import { createClient, resolveChatId, normalizeChatId } from "./listener";
import { MessageStore } from "./messageStore";
import path from "path";

// One-off research script: dumps the last N messages of any group/channel
// by name to data/history-<slug>.jsonl for manual signal-format inspection.
// Usage: npm run fetch:history:byname -- "DGT's | 🥷Private Pro 5" 100
const groupName = process.argv[2];
const limit = Number(process.argv[3] ?? 100);

if (!groupName) {
  console.error('Usage: tsx src/fetchHistoryByName.ts "<group name>" [limit]');
  process.exit(1);
}

function slugify(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
}

async function main(): Promise<void> {
  const outputPath = path.join(process.cwd(), "data", `history-${slugify(groupName)}.jsonl`);
  const store = new MessageStore(outputPath);

  const client = await createClient();

  console.log(`Resolving target group "${groupName}"...`);
  const targetChatId = await resolveChatId(client, groupName);

  console.log(`Fetching last ${limit} messages from chat ID: ${targetChatId}`);

  const messages = await client.getMessages(targetChatId, { limit });

  let saved = 0;
  for (const message of messages) {
    const chatId = normalizeChatId(message.chatId) ?? targetChatId;
    const text = message.message;
    if (!text || typeof text !== "string") {
      continue;
    }

    await store.append({
      chatId,
      chatTitle: groupName,
      messageId: message.id,
      text,
      receivedAt: new Date((message.date ?? 0) * 1000).toISOString()
    });
    saved++;
  }

  console.log(`Saved ${saved} messages to ${outputPath}`);
  await client.disconnect();
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
