import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

import { waitForAnimations } from "../helpers/animations";
import { TEST_IDENTITIES, installMockBridge } from "../helpers/bridge";

async function waitForMockLiveSubscription(page: Page, channelName: string) {
  await expect
    .poll(() =>
      page.evaluate(
        ({ name }) =>
          window.__BUZZ_E2E_HAS_MOCK_LIVE_SUBSCRIPTION__?.({
            channelName: name,
          }) ?? false,
        { name: channelName },
      ),
    )
    .toBe(true);
}
async function seedThread(page: Page, channelName: string, label: string) {
  return page.evaluate(
    ({ channel, surface, alicePubkey, bobPubkey }) => {
      const root = window.__BUZZ_E2E_EMIT_MOCK_MESSAGE__?.({
        channelName: channel,
        content: `${surface} planning thread`,
        createdAt: 1_708_000_000,
        pubkey: alicePubkey,
      });
      if (!root) throw new Error("Failed to seed inline thread root");

      const reply = window.__BUZZ_E2E_EMIT_MOCK_MESSAGE__?.({
        channelName: channel,
        content: `${surface} direct reply`,
        createdAt: 1_708_000_001,
        parentEventId: root.id,
        pubkey: bobPubkey,
      });
      if (!reply) throw new Error("Failed to seed inline thread reply");

      const nestedReply = window.__BUZZ_E2E_EMIT_MOCK_MESSAGE__?.({
        channelName: channel,
        content: `${surface} nested reply`,
        createdAt: 1_708_000_002,
        parentEventId: reply.id,
        pubkey: alicePubkey,
      });
      if (!nestedReply) throw new Error("Failed to seed nested inline reply");

      return {
        nestedReplyContent: nestedReply.content,
        replyContent: reply.content,
        rootId: root.id,
      };
    },
    {
      alicePubkey: TEST_IDENTITIES.alice.pubkey,
      bobPubkey: TEST_IDENTITIES.bob.pubkey,
      channel: channelName,
      surface: label,
    },
  );
}

for (const surface of [
  {
    channelName: "general",
    label: "Channel",
    screenshot: "test-results/inline-thread-replies/channel.png",
  },
  {
    channelName: "alice-tyler",
    label: "DM",
    screenshot: "test-results/inline-thread-replies/dm.png",
  },
]) {
  test(`${surface.label} thread replies expand in the main conversation`, async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 720 });
    await installMockBridge(page);
    await page.goto("/");
    await page.getByTestId(`channel-${surface.channelName}`).click();
    await expect(page.getByTestId("chat-title")).toHaveText(
      surface.channelName,
    );
    await waitForMockLiveSubscription(page, surface.channelName);

    const thread = await seedThread(page, surface.channelName, surface.label);
    const summary = page.locator(
      `[data-testid="message-thread-summary"][data-thread-head-id="${thread.rootId}"]`,
    );
    const toggle = page.locator(
      `[data-testid="message-thread-inline-toggle"][data-thread-head-id="${thread.rootId}"]`,
    );
    await expect(summary).toBeVisible();
    await expect(toggle).toHaveAttribute("aria-pressed", "false");
    await expect(
      page.getByText(thread.replyContent, { exact: true }),
    ).toHaveCount(0);

    await summary.click();
    await expect(page.getByTestId("message-thread-panel")).toBeVisible();
    await page.getByTestId("auxiliary-panel-close").click();
    await expect(page.getByTestId("message-thread-panel")).toHaveCount(0);

    await toggle.focus();
    await toggle.press("Enter");
    await expect(toggle).toHaveAttribute("aria-pressed", "true");
    await expect(toggle).toHaveText("Hide replies");
    const inlineReplies = page.getByTestId("message-thread-inline-replies");
    await expect(inlineReplies).toBeVisible();
    await expect(
      inlineReplies.getByText(thread.replyContent, { exact: true }),
    ).toBeVisible();
    await expect(
      inlineReplies.getByText(thread.nestedReplyContent, { exact: true }),
    ).toBeVisible();
    await expect(page.getByTestId("message-thread-panel")).toHaveCount(0);

    await waitForAnimations(page);
    await inlineReplies.locator("..").screenshot({ path: surface.screenshot });

    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-pressed", "false");
    await expect(inlineReplies).toHaveCount(0);
  });
}
