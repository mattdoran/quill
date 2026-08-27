const audioPlayer = document.getElementById('audio');
const annotationForm = document.querySelector('form[action$="/annotations"]');
const unsavedIndicator = document.querySelector('[data-unsaved]');
const transcriptRows = Array.from(document.querySelectorAll('[data-row]')).map(element => ({
  element,
  start: Number(element.querySelector('[data-play]').dataset.start),
}));
let activeIndex = null;
let submitting = false;

const annotationSnapshot = () => JSON.stringify(
  Array.from(new FormData(annotationForm).entries())
    .filter(([name]) => name.startsWith('label:'))
    .sort(([left], [right]) => left.localeCompare(right))
);
const savedSnapshot = annotationSnapshot();
const hasUnsavedChanges = () => annotationSnapshot() !== savedSnapshot;

const updateUnsavedIndicator = () => {
  unsavedIndicator.hidden = !hasUnsavedChanges();
};

const setActiveRow = (index, follow) => {
  if (index === activeIndex) return;
  if (activeIndex !== null) transcriptRows[activeIndex].element.classList.remove('active');
  activeIndex = index;
  transcriptRows[index].element.classList.add('active');
  if (follow) transcriptRows[index].element.scrollIntoView({ block: 'center', behavior: 'smooth' });
};

const rowIndexAt = time => {
  let low = 0;
  let high = transcriptRows.length - 1;
  let result = -1;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    if (transcriptRows[middle].start <= time) {
      result = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return result;
};

document.body.addEventListener('click', event => {
  const button = event.target.closest('[data-play]');
  if (!button) return;
  audioPlayer.currentTime = Number(button.dataset.start);
  audioPlayer.play().catch(reason => report({ msg: String(reason), kind: 'audio' }));
  setActiveRow(transcriptRows.findIndex(row => row.element === button.closest('[data-row]')), false);
});

audioPlayer.addEventListener('timeupdate', () => {
  const index = rowIndexAt(audioPlayer.currentTime);
  if (index >= 0) setActiveRow(index, true);
});

annotationForm.addEventListener('change', updateUnsavedIndicator);
annotationForm.addEventListener('submit', () => { submitting = true; });
window.addEventListener('pageshow', () => {
  submitting = false;
  updateUnsavedIndicator();
});
window.addEventListener('beforeunload', event => {
  if (!submitting && hasUnsavedChanges()) {
    event.preventDefault();
    event.returnValue = '';
  }
});

const report = body =>
  fetch('/api/log', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }).catch(() => {});

window.addEventListener('error', event =>
  report({ msg: event.message, src: event.filename, line: event.lineno }));
window.addEventListener('unhandledrejection', event =>
  report({ msg: String(event.reason), kind: 'promise' }));
document.body.addEventListener('htmx:responseError', event =>
  report({ msg: String(event.detail), kind: 'htmx' }));
