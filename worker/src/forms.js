/**
 * Keep the leave Form's Name dropdown in step with the rota's Team tab.
 *
 * The Form holds its own copy of the names, so without this every rotation
 * means editing the Team tab *and* the Form, and forgetting the second leaves
 * a new doctor unable to book leave. The Team tab is the one list; this runs
 * with each rota sync and rewrites the dropdown only when the two differ.
 *
 * Only the Name question's options are touched. The item keeps its question
 * ID, so the responses sheet keeps its columns and every past answer stays
 * where it is. Re-creating the question would add a fresh column instead.
 *
 * Needs ROTA_FORM_ID (the ID in the Form's *edit* URL, set as a secret: the
 * same ID also opens the responder view, which takes anonymous submissions)
 * and the `forms.body` scope on the refresh token (see get-refresh-token.mjs).
 */

import { accessToken } from './google_auth.js';
import { squash } from './sheets.js';

const API = 'https://forms.googleapis.com/v1/forms';

/** Question titles that mean "who is this", as the Leave tab reads them. */
const NAME_TITLES = ['name', 'fullname', 'doctor', 'person', 'staff', 'who', 'whoareyou'];

async function api(token, method, path, body) {
  const resp = await fetch(`${API}/${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!resp.ok) {
    const detail = await resp.text();
    const hint = resp.status === 403
      ? ' (does the refresh token have the forms.body scope? re-mint with get-refresh-token.mjs)'
      : '';
    throw new Error(`forms ${method} ${path} -> ${resp.status}${hint} ${detail}`);
  }
  return resp.json();
}

/**
 * The index and item of the Form's name dropdown, or null. A choice question
 * whose title squashes to a known name title: "Name", "Your name?", "Doctor".
 */
export function findNameItem(items = []) {
  for (let index = 0; index < items.length; index++) {
    const item = items[index];
    if (!item.questionItem?.question?.choiceQuestion) continue;
    const title = squash(item.title);
    if (NAME_TITLES.includes(title) || title === 'yourname') return { index, item };
  }
  return null;
}

export async function syncFormNames(env, names) {
  const formId = env.ROTA_FORM_ID;
  if (!formId) return { skipped: 'ROTA_FORM_ID not set' };
  // An empty Team tab is a mid-edit, not a team of nobody. A Form nobody can
  // pick a name in is worse than one with last rotation's names.
  if (!names.length) return { skipped: 'no names' };

  const token = await accessToken(env);
  const form = await api(token, 'GET', encodeURIComponent(formId));
  const found = findNameItem(form.items);
  if (!found) {
    console.log('rota: the Form has no Name dropdown to keep in step');
    return { skipped: 'no Name question' };
  }

  const { index, item } = found;
  const choice = item.questionItem.question.choiceQuestion;
  const current = (choice.options || []).filter((o) => !o.isOther).map((o) => o.value);
  if (JSON.stringify(current) === JSON.stringify(names)) return { changed: false };

  // Keep an "Other…" option if someone added one by hand.
  const other = (choice.options || []).filter((o) => o.isOther);
  const options = [...names.map((value) => ({ value })), ...other];
  await api(token, 'POST', `${encodeURIComponent(formId)}:batchUpdate`, {
    requests: [{
      updateItem: {
        item: {
          ...item,
          questionItem: {
            ...item.questionItem,
            question: { ...item.questionItem.question, choiceQuestion: { ...choice, options } },
          },
        },
        location: { index },
        updateMask: 'questionItem.question.choiceQuestion.options',
      },
    }],
  });

  const added = names.filter((n) => !current.includes(n));
  const removed = current.filter((n) => !names.includes(n));
  console.log(
    `rota: Form names updated (${names.length}; added ${JSON.stringify(added)}, removed ${JSON.stringify(removed)})`,
  );
  return { changed: true, added, removed };
}
