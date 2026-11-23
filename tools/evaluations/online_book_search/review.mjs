import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const args = process.argv.slice(2);
let casesPath = fileURLToPath(new URL('./cases.json', import.meta.url));
const casesFlag = args.indexOf('--cases-file');
if (casesFlag !== -1) {
  const [, flagValue] = args.splice(casesFlag, 2);
  if (!flagValue) throw new Error('--cases-file needs a JSON file path');
  casesPath = flagValue;
}
const dataset = fs.readFileSync(casesPath);
const cases = JSON.parse(dataset);
const [mode, reportFile, recheckFile] = args;

if (mode === 'flow-dataset') {
  const dataset = cases.filter(row => !row.route && !row.after).map(row => {
    const { id, prompt, linked, ...expected } = row;
    return {
      testCaseId: id,
      input: {
        book_search: true,
        message: prompt,
        model_id: 'deepseek-flash',
        ...(linked ? { book_search_linked_book: linked } : {}),
      },
      reference: expected,
    };
  });
  console.log(JSON.stringify(dataset, null, 2));
} else if (mode === 'score' && reportFile) {
  const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
  const byId = new Map(report.rows.map(row => [row.id, row]));
  if (report.dataset && report.dataset.sha256 !== createHash('sha256').update(dataset).digest('hex')) {
    throw new Error('Report dataset does not match the requested case file');
  }
  if (report.rows.length !== cases.length || byId.size !== cases.length ||
      cases.some(row => typeof byId.get(row.id)?.pass !== 'boolean')) {
    throw new Error('Report must cover each frozen case exactly once');
  }
  const filesRechecked = new Map();
  if (recheckFile) {
    const recheck = JSON.parse(fs.readFileSync(recheckFile, 'utf8'));
    if (report.release.commit !== recheck.release.commit ||
        report.release.image !== recheck.release.image) {
      throw new Error('The targeted recheck must use the same release image');
    }
    if (report.dataset && recheck.dataset && report.dataset.sha256 !== recheck.dataset.sha256) {
      throw new Error('The targeted recheck must use the same case file');
    }
    if (report.alternate_sources?.sha256 !== recheck.alternate_sources?.sha256) {
      throw new Error('The targeted recheck must use the same alternate source file');
    }
    for (const row of recheck.rows) {
      const initial = byId.get(row.id);
      if (initial?.reason === 'wrong_file_offered' &&
          row.reason === initial.reason && row.file) {
        filesRechecked.set(row.id, row.file);
      }
    }
  }
  const count = (filter, passed = row => row.pass) => {
    const population = cases.filter(filter);
    return {
      passed: population.filter(row => passed(byId.get(row.id))).length,
      total: population.length,
    };
  };
  const independent = count(row => row.kind === 'file' && row.group !== 'prompt-variant');
  const variants = count(row => row.group === 'prompt-variant');
  const controls = count(row => row.group === 'control');
  const discovery = count(row => row.group === 'exploratory');
  const importRequests = count(row => row.kind === 'file');
  const downloadEntries = count(row => row.kind === 'file', row => row.download_entry_found === true);
  const hasVerifiedFile = row => Boolean(row.file || filesRechecked.has(row.id));
  const filesVerified = count(row => row.kind === 'file', hasVerifiedFile);
  const independentFilesVerified = count(
    row => row.kind === 'file' && row.group !== 'prompt-variant', hasVerifiedFile,
  );
  const groupNames = [...new Set(cases.map(row => row.group))];
  const groups = Object.fromEntries(groupNames.map(group => [group, count(row => row.group === group)]));
  const requested = row => row.requested_file === true;
  const verifiedDelivery = row => row.pass && hasVerifiedFile(row);
  const requestedFiles = count(requested, verifiedDelivery);
  const availabilityUnconfirmed = count(
    row => requested(row) && ['no_file', 'availability_unconfirmed'].includes(row.kind),
    verifiedDelivery,
  );
  const requestedFilesByGroup = Object.fromEntries(
    groupNames.map(group => [group, count(row => requested(row) && row.group === group, verifiedDelivery)])
      .filter(([, result]) => result.total > 0),
  );
  const stats = values => {
    const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
    if (!sorted.length) return { count: 0 };
    const percentile = p => sorted[Math.ceil(sorted.length * p) - 1];
    return {
      count: sorted.length,
      mean: Math.round(sorted.reduce((sum, ms) => sum + ms, 0) / sorted.length),
      p50: percentile(0.5),
      p90: percentile(0.9),
      max: sorted.at(-1),
    };
  };
  const fileRows = cases.filter(row => row.kind === 'file' || requested(row)).map(row => byId.get(row.id));
  const timingMs = {
    allRequests: stats(report.rows.map(row => row.ms)),
    fileRequests: stats(fileRows.map(row => row.ms)),
    successfulFileRequests: stats(fileRows.filter(verifiedDelivery).map(row => row.ms)),
    fileSearchAndReply: stats(fileRows.map(row => row.search_and_reply_ms)),
    successfulFilePreparation: stats(fileRows.map(row => row.prepare_ms)),
    fileTransfer: stats(fileRows.map(row => row.file_transfer_ms)),
    failedDownloads: stats(fileRows.filter(row => row.download?.stage !== 'complete')
      .map(row => row.download?.ms)),
  };
  const regressionGate = independent.passed / independent.total >= 0.9 &&
    importRequests.passed / importRequests.total >= 0.9 &&
    independentFilesVerified.passed / independentFilesVerified.total >= 0.9 &&
    filesVerified.passed / filesVerified.total >= 0.9 &&
    controls.passed === controls.total;
  const requestedFileGate = requestedFiles.total ? requestedFiles.passed / requestedFiles.total >= 0.9 : null;
  const gate = regressionGate && requestedFileGate !== false;
  console.log(JSON.stringify({
    release: report.release,
    dataset: report.dataset ?? { name: path.basename(casesPath) },
    alternateSources: report.alternate_sources,
    independent, importRequests, downloadEntries, filesVerified, independentFilesVerified,
    verifiedOnRecheck: [...filesRechecked.keys()], variants, controls, discovery, groups, timingMs, gate,
    ...(requestedFiles.total ? { requestedFiles, availabilityUnconfirmed, requestedFilesByGroup, requestedFileGate } : {}),
    rows: cases.map(row => {
      const actual = byId.get(row.id);
      return {
        id: row.id, pass: actual.pass, reason: actual.reason, modelCalls: actual.model_calls,
        verifiedFile: actual.file ?? filesRechecked.get(row.id),
        toolNames: actual.tools, candidates: actual.candidates?.length ?? 0, ms: actual.ms,
        searchAndReplyMs: actual.search_and_reply_ms,
        prepareMs: actual.prepare_ms, fileTransferMs: actual.file_transfer_ms,
        download: actual.download,
        importOutcome: actual.import_outcome,
        startedAt: actual.started_at, endedAt: actual.ended_at,
        clientImportVerified: actual.client_import_verified === true,
      };
    }),
  }, null, 2));
  if (!gate) process.exitCode = 2;
} else {
  console.error('Usage: node review.mjs flow-dataset | node review.mjs score <report.json> [targeted-recheck.json] [--cases-file <cases.json>]');
  process.exitCode = 1;
}
