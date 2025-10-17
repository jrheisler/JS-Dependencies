importScripts('graph-preprocessing.js');

self.addEventListener('message', (event) => {
  const data = event.data || {};
  const { id, type, payload } = data;
  if(type !== 'process'){
    return;
  }
  try {
    const result = self.GraphPreprocessing.preprocessGraph(payload);
    self.postMessage({ id, type: 'result', result });
  } catch (error) {
    const message = error && error.message ? error.message : String(error);
    self.postMessage({ id, type: 'error', error: { message, stack: error && error.stack ? String(error.stack) : null } });
  }
});
