import { expect, test } from '@playwright/test';

const email = 'cs001@hsp.local';
const password = 'cs111111';

test('smoke flow works', async ({ page }) => {
  await page.goto('/login');

  await expect(
    page.getByRole('heading', { name: '登录 HSP 客服端' }),
  ).toBeVisible();

  await page.getByRole('textbox', { name: '* 邮箱' }).fill(email);
  await page.getByRole('textbox', { name: '* 密码' }).fill(password);
  await page.getByRole('button', { name: 'Login' }).click();

  await expect(page).toHaveURL(/\/dashboard$/, {
    timeout: 15000,
  });
  await expect(
    page.getByRole('heading', { name: '客服端运营总览' }),
  ).toBeVisible();

  await page.getByRole('menuitem', { name: '订单中心' }).click();

  await expect(page).toHaveURL(/\/orders$/);
  await expect(
    page.getByRole('button', { name: 'plus 新建订单' }),
  ).toBeVisible();

  await page.getByRole('button', { name: `user ${email}` }).click();
  await page.getByText('退出登录').click();

  await expect(page).toHaveURL(/\/login$/);
  await expect(page.getByRole('button', { name: 'Login' })).toBeVisible();
});
