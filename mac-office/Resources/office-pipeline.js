window.createOfficePipeline = ({bridge, t, language}) => {
  const find = id => document.getElementById(id);
  const workspace = find('pipeline-workspace');
  const repositoryPicker = find('pipeline-repository');
  const actionsButton = find('pipeline-show-actions');
  const releasesButton = find('pipeline-show-releases');
  const refresh = find('pipeline-refresh');
  const auth = find('pipeline-auth');
  const runPicker = find('pipeline-run');
  const runLink = find('pipeline-run-link');
  const followLatest = find('pipeline-follow-latest');
  const history = find('pipeline-history');
  const vercelLink = find('pipeline-vercel-link');
  const vercelForm = find('pipeline-vercel-project-form');
  const vercelProjectID = find('pipeline-vercel-project-id');
  const vercelTeamID = find('pipeline-vercel-team-id');
  const vercelRemove = find('pipeline-vercel-project-remove');
  const labels = new Map(Object.entries({
    queued: '排队中', pending: '等待中', requested: '等待中', waiting: '等待中',
    in_progress: '进行中', success: '通过', failure: '失败', error: '失败',
    cancelled: '已取消', skipped: '已跳过', timed_out: '超时',
    action_required: '需要处理', neutral: '中性', stale: '已过期',
    startup_failure: '启动失败', building: '构建中', initializing: '初始化中', ready: '就绪',
    canceled: '已取消', blocked: '阻塞'
  }));
  const errors = new Map(Object.entries({
    inaccessible: 'GitHub 无法公开读取此仓库的 Actions。',
    rateLimited: 'GitHub 请求已达上限，稍后可手动刷新。',
    cliMissing: '未找到本机 GitHub CLI（gh）。',
    cliUnavailable: '本机 gh 无法读取此数据。请检查登录和仓库访问权限。',
    unavailable: '暂时无法读取 GitHub 数据。'
  }));
  const releaseSources = new Map([
    ['vercel', {name: 'Vercel', errors: new Map(Object.entries({
      unlinked: '此目录没有已关联的 Vercel 项目。',
      cliMissing: '已识别 Vercel 项目。使用本机 Vercel CLI 登录后可读取发布记录。',
      cliTooOld: '读取发布记录需要支持 vercel api 的 Vercel CLI。',
      cliUnavailable: '本机 Vercel CLI 无法读取发布记录。请检查已有登录和项目访问权限。',
      unavailable: '暂时无法读取 Vercel 发布记录。'
    }))}]
  ]);
  const environments = new Map([['production', '生产目标'], ['preview', '预览']]);
  const releasePhases = new Map([['staged', '待正式发布'], ['promoted', '已执行生产发布']]);
  const endedJobs = new Set(['success', 'failure', 'error', 'completed', 'cancelled', 'canceled', 'skipped',
    'timed_out', 'action_required', 'neutral', 'stale', 'startup_failure']);

  let source = 'actions';
  let thread, repository, result, pinnedRun, timer, projectsKey;
  let repositories = [];
  let repositoryRequest = 0;
  let loadingRepositories = false;
  let projects = new Map();
  let active = false;
  let ghRepositories = new Set();
  let vercelProjects = new Map();
  let preferenceSaveFailed = false;
  let busy = false;
  let request = 0;
  const usesCLI = () => source === 'actions' && ghRepositories.has(repository);

  function node(tag, text, className = '') {
    const element = document.createElement(tag);
    if (text !== undefined) element.textContent = text;
    if (className) element.className = className;
    return element;
  }

  function state(value) {
    const badge = node('span', t(labels.get(value) ?? '状态未知'), 'pipeline-status');
    badge.dataset.state = value;
    return badge;
  }

  function time(value) {
    const date = new Date(value ?? '');
    if (!Number.isFinite(date.getTime())) return node('span');
    const time = node('time', ' · ' + date.toLocaleString(language(), {
      month: 'numeric', day: 'numeric', hour: 'numeric', minute: '2-digit'
    }), 'pipeline-time');
    time.dateTime = date.toISOString();
    return time;
  }

  function note(id, error, hasPrevious, empty) {
    const element = find(id);
    element.hidden = !(error || empty);
    element.textContent = noteText(error, hasPrevious, empty, errors, '暂时无法读取 GitHub 数据。');
  }

  function noteText(error, hasPrevious, empty, messages, fallback) {
    if (!error) return t(empty) ?? '';
    const message = t(messages?.get(error) ?? fallback);
    return hasPrevious ? message + ' ' + t('显示上次读取的结果。') : message;
  }

  function openLink(source, index, release) {
    if (!busy && result && index >= 0) bridge({action: 'openPipelineLink', request, source, index, release: release ?? null});
  }

  function linkButton(source, index, release) {
    const button = node('button', t('部署详情'));
    button.type = 'button';
    button.disabled = busy;
    button.addEventListener('click', () => openLink(source, index, release));
    return button;
  }

  function renderProgress() {
    const overview = find('pipeline-progress');
    overview.hidden = source !== 'actions' || !result;
    if (overview.hidden) return;
    const run = result.runs.find(item => item.id === result.latestRunID);
    const context = find('pipeline-progress-context');
    context.hidden = !run;
    context.replaceChildren();
    if (run) {
      const label = [run.number ? '#' + run.number : null, run.attempt > 1 ? t('第 {0} 次运行', run.attempt) : null,
        run.branch, run.commit?.slice(0, 7)].filter(Boolean).join(' · ');
      context.append(node('span', label), time(run.triggeredAt ?? run.updated));
    }
    const ci = find('pipeline-ci-progress');
    ci.replaceChildren();
    if (run) {
      const matching = run.commit ? result.runs.filter(item => item.commit === run.commit) : [run];
      const seen = new Set();
      for (const item of matching) {
        const key = (item.workflowID ?? item.id) + '\n' + (item.branch ?? '');
        if (seen.has(key)) continue;
        seen.add(key);
        const row = node('div', undefined, 'pipeline-row');
        row.append(node('span', item.name), state(item.state));
        ci.append(row);
      }
      if (run.id === result.runID && !result.jobsError && result.jobs.length) {
        const ended = result.jobs.filter(job => endedJobs.has(job.state));
        ci.append(node('p', t('{0}/{1} 个作业已结束', ended.length, result.jobs.length), 'dialog-note'));
        const current = result.jobs.find(job => job.state === 'in_progress');
        if (current) {
          const step = current.steps.find(item => item.state === 'in_progress');
          ci.append(node('p', [current.name, step?.name].filter(Boolean).join(' · '), 'dialog-note'));
        }
      }
      if (result.actionsError) ci.append(node('p', t('显示上次读取的结果。'), 'dialog-note'));
    } else {
      ci.append(node('p', noteText(result.actionsError, false, '此仓库暂无可见的 GitHub Actions 运行。',
        errors, '暂时无法读取 GitHub 数据。'), 'dialog-note'));
    }
    const deployments = find('pipeline-vercel-progress');
    deployments.replaceChildren();
    if (!result.releases.length) {
      deployments.append(node('p', t(run?.commit ? '本机未识别到关联的 Vercel 项目。' : '等待工作流提供提交号。'), 'dialog-note'));
      return;
    }
    result.releases.forEach((release, releaseIndex) => {
      if (release.isLatestFallback && release.records.length) {
        if (run?.commit) deployments.append(node('p', t('此提交无 Vercel 部署'), 'dialog-note'));
        deployments.append(node('strong', t('最近一次前端部署')));
      }
      if (release.error || !release.records.length) {
        const text = noteText(release.error, release.records.length, '该提交尚无匹配部署。',
          releaseSources.get(release.provider)?.errors, '暂时无法读取发布记录。');
        deployments.append(node('p', [release.project, text].filter(Boolean).join(' · '), 'dialog-note'));
      }
      const seen = new Set();
      release.records.forEach((record, index) => {
        if (seen.has(record.environment)) return;
        seen.add(record.environment);
        const row = node('div', undefined, 'pipeline-row');
        const summary = node('div');
        const environment = environments.get(record.environment);
        const phase = releasePhases.get(record.release);
        summary.append(node('span', [release.project, environment ? t(environment) : record.environment]
          .filter(Boolean).join(' · ') + ' '), state(record.state));
        if (phase) summary.append(node('span', ' · ' + t(phase), 'pipeline-status'));
        if (record.errorCode) summary.append(node('div', record.errorCode, 'pipeline-time'));
        if (release.isLatestFallback) {
          const detail = node('div', undefined, 'pipeline-time');
          if (record.commit) {
            const sha = node('code', record.commit.slice(0, 7));
            sha.title = record.commit;
            detail.append(sha);
          } else {
            detail.append(t('提交号不可用'));
          }
          detail.append(time(record.observedAt));
          summary.append(detail);
        }
        row.append(summary);
        if (record.canOpen) row.append(linkButton(release.provider, index, releaseIndex));
        deployments.append(row);
      });
    });
  }

  function renderReleases(releases) {
    find('pipeline-releases').hidden = !releases.length;
    find('pipeline-deployments').replaceChildren(...releases.map((release, releaseIndex) => {
      const provider = releaseSources.get(release.provider);
      const section = node('div', undefined, 'pipeline-release');
      const name = provider?.name ?? release.provider;
      section.append(node('h3', [name, release.project].filter(Boolean).join(' · ')));
      if (release.error || !release.records.length) {
        section.append(node('p', noteText(release.error, release.records.length, '此项目暂无可见的发布记录。',
          provider?.errors, '暂时无法读取发布记录。'), 'dialog-note'));
      } else {
        section.append(node('p', t('通过本机 CLI 只读查询'), 'dialog-note'));
      }
      const rows = node('ul', undefined, 'pipeline-list');
      release.records.forEach((deployment, index) => {
        const row = node('li', undefined, 'pipeline-row pipeline-deployment');
        const summary = node('div');
        const environment = environments.get(deployment.environment);
        const phase = releasePhases.get(deployment.release);
        summary.append(node('strong', (environment ? t(environment) : deployment.environment) + ' · '));
        summary.append(state(deployment.state));
        if (phase) summary.append(node('span', ' · ' + t(phase), 'pipeline-status'));
        summary.append(time(deployment.observedAt));
        const commit = [deployment.branch, deployment.commit?.slice(0, 7)].filter(Boolean);
        if (deployment.commit && result.sha?.startsWith(deployment.commit)) commit.push(t('当前提交'));
        if (commit.length) summary.append(node('div', commit.join(' · '), 'pipeline-time'));
        if (deployment.errorCode) summary.append(node('code', deployment.errorCode));
        row.append(summary);
        if (deployment.canOpen) row.append(linkButton(release.provider, index, releaseIndex));
        rows.append(row);
      });
      section.append(rows);
      return section;
    }));
  }

  function render() {
    if (!active) return;
    const actions = source === 'actions';
    const hasRepository = actions && Boolean(repository);
    const useCLI = usesCLI();
    actionsButton.setAttribute('aria-pressed', String(actions));
    releasesButton.setAttribute('aria-pressed', String(!actions));
    find('pipeline-repository-picker').hidden = !actions;
    find('pipeline-workspace-picker').hidden = actions;
    repositoryPicker.options[0].textContent = t(loadingRepositories ? '正在识别本机仓库…'
      : repositories.length ? '选择仓库' : '未识别到 GitHub 仓库');
    repositoryPicker.disabled = loadingRepositories || !repositories.length;
    workspace.options[0].textContent = t(projects.size ? '选择项目聊天' : '暂无项目聊天');
    find('pipeline-query-tools').hidden = !actions && !thread;
    vercelLink.hidden = !hasRepository;
    vercelLink.disabled = busy || loadingRepositories;
    vercelLink.textContent = t(vercelProjects.has(repository) ? '编辑 Vercel 关联' : '关联 Vercel 项目');
    find('pipeline-auth-tools').hidden = !hasRepository;
    find('pipeline-revision').textContent = hasRepository ? repository : '';
    refresh.textContent = t(actions && !repository ? '刷新仓库' : '刷新');
    refresh.disabled = busy || loadingRepositories;
    auth.disabled = busy || loadingRepositories;
    auth.hidden = !hasRepository;
    auth.textContent = t(useCLI ? '改用公开查询' : '使用已有 gh 登录');
    find('pipeline-source').textContent = hasRepository
      ? 'GitHub · ' + t(useCLI ? '通过本机 gh 只读查询' : '公开查询 · 无需登录') : '';
    find('pipeline-feedback').textContent = busy
      ? t(actions ? '正在读取 GitHub Actions…' : '正在读取发布记录…')
      : !actions && result && !result.releases.length ? t('无法识别此聊天的工作目录。') : '';
    const preferenceNote = find('pipeline-preference-note');
    preferenceNote.hidden = !actions || !preferenceSaveFailed;
    preferenceNote.textContent = preferenceSaveFailed ? t('无法保存 CI 仓库偏好。') : '';
    find('pipeline-actions').hidden = !actions || !result;
    renderProgress();
    renderReleases(actions ? [] : result?.releases ?? []);
    if (!actions || !result) return;

    const {runs, jobs} = result;
    history.hidden = !runs.length;
    note('pipeline-actions-note', runs.length ? result.actionsError : undefined, runs.length);
    note('pipeline-jobs-note', result.jobsError, jobs.length,
         jobs.length ? undefined : '此运行暂无可见的作业。');

    const selected = runs.findIndex(run => run.id === result.runID);
    runPicker.replaceChildren(...runs.map(run => {
      const option = node('option', [run.name, run.branch, t(labels.get(run.state) ?? '状态未知'),
        run.attempt > 1 ? t('第 {0} 次运行', run.attempt) : null].filter(Boolean).join(' · '));
      option.value = run.id;
      return option;
    }));
    runPicker.selectedIndex = selected;
    runPicker.disabled = busy;
    runLink.disabled = busy;
    followLatest.hidden = !pinnedRun;
    followLatest.disabled = busy;
    find('pipeline-run-details').hidden = selected < 0;
    const run = runs[selected];
    if (run) {
      find('pipeline-run-state').replaceChildren(state(run.state), time(run.updated));
    }

    find('pipeline-jobs').replaceChildren(...jobs.map(job => {
      const card = node('li');
      const row = node('div', undefined, 'pipeline-row');
      row.append(node('strong', job.name), state(job.state));
      card.append(row);
      if (job.steps.length) {
        const steps = node('ul', undefined, 'pipeline-list pipeline-steps');
        for (const step of job.steps) {
          const line = node('li', undefined, 'pipeline-row');
          line.append(node('span', step.name), state(step.state));
          steps.append(line);
        }
        card.append(steps);
      }
      return card;
    }));

  }

  function load(automatic = false) {
    if (!active || busy || (source === 'actions' ? !repository || loadingRepositories : !thread)) return;
    clearTimeout(timer);
    busy = true;
    render();
    const target = source === 'actions' ? {repository} : {id: thread};
    bridge({action: 'loadPipeline', ...target, request: ++request, run: pinnedRun ?? null, automatic});
  }

  function reset() {
    clearTimeout(timer);
    if (busy || result || loadingRepositories) bridge({action: 'closePipeline'});
    busy = false;
    loadingRepositories = false;
    result = pinnedRun = undefined;
    history.open = false;
    closeVercelForm();
  }

  function closeVercelForm() {
    vercelForm.hidden = true;
    vercelLink.setAttribute('aria-expanded', 'false');
  }

  function rememberVercelProject(project) {
    if (!active || source !== 'actions' || !repository || busy || loadingRepositories) return;
    if (project) vercelProjects.set(repository, project);
    else vercelProjects.delete(repository);
    bridge({action: 'rememberPipelineVercelProject', repository, project});
    reset();
    load();
  }

  function discoverRepositories() {
    if (!active || source !== 'actions') return;
    loadingRepositories = true;
    render();
    bridge({action: 'loadPipelineRepositories', request: ++repositoryRequest});
  }

  function showSource(target) {
    if (source === target) return;
    reset();
    source = target;
    if (source === 'actions') {
      discoverRepositories();
    } else {
      render();
      load();
    }
  }

  actionsButton.addEventListener('click', () => showSource('actions'));
  releasesButton.addEventListener('click', () => showSource('releases'));
  repositoryPicker.addEventListener('change', () => {
    if (loadingRepositories) return;
    reset();
    repository = repositories.includes(repositoryPicker.value) ? repositoryPicker.value : undefined;
    bridge({action: 'rememberPipelineRepository', repository: repository ?? null});
    render();
    load();
  });
  workspace.addEventListener('change', () => {
    reset();
    thread = projects.has(workspace.value) ? workspace.value : undefined;
    render();
    load();
  });
  refresh.addEventListener('click', () => {
    if (source === 'actions' && !repository) discoverRepositories();
    else load();
  });
  auth.addEventListener('click', () => {
    if (!repository || busy || loadingRepositories || source !== 'actions') return;
    const useCLI = !usesCLI();
    if (useCLI) ghRepositories.add(repository);
    else ghRepositories.delete(repository);
    bridge({action: 'rememberPipelineAuthentication', repository, useCLI});
    load();
  });
  vercelLink.addEventListener('click', () => {
    if (!repository || busy || loadingRepositories) return;
    if (!vercelForm.hidden) {
      closeVercelForm();
      return;
    }
    const project = vercelProjects.get(repository);
    vercelProjectID.value = project?.projectId ?? '';
    vercelTeamID.value = project?.orgId ?? '';
    vercelProjectID.setCustomValidity('');
    vercelTeamID.setCustomValidity('');
    vercelRemove.hidden = !project;
    vercelForm.hidden = false;
    vercelLink.setAttribute('aria-expanded', 'true');
    vercelProjectID.focus();
  });
  find('pipeline-vercel-project-cancel').addEventListener('click', closeVercelForm);
  vercelRemove.addEventListener('click', () => rememberVercelProject(null));
  for (const field of [vercelProjectID, vercelTeamID]) {
    field.addEventListener('input', () => field.setCustomValidity(''));
  }
  vercelForm.addEventListener('submit', event => {
    event.preventDefault();
    const projectId = vercelProjectID.value.trim();
    const orgId = vercelTeamID.value.trim();
    if (!/^prj_[A-Za-z0-9_-]{1,120}$/.test(projectId)) {
      vercelProjectID.setCustomValidity(t('请输入有效的 Vercel 项目 ID。'));
      vercelProjectID.reportValidity();
      return;
    }
    if (orgId && !/^team_[A-Za-z0-9_-]{1,123}$/.test(orgId)) {
      vercelTeamID.setCustomValidity(t('请输入有效的 Vercel 团队 ID。'));
      vercelTeamID.reportValidity();
      return;
    }
    const before = vercelProjects.get(repository);
    const project = {projectId, orgId};
    if (before?.projectId === projectId && before?.projectName) project.projectName = before.projectName;
    rememberVercelProject(project);
  });
  runPicker.addEventListener('change', () => {
    pinnedRun = Number(runPicker.value);
    load();
  });
  followLatest.addEventListener('click', () => {
    pinnedRun = undefined;
    load();
  });
  runLink.addEventListener('click', () => openLink('actions', runPicker.selectedIndex));

  window.officeReceivePipelineRepositories = (choices, preferences, receivedRequest) => {
    if (!active || source !== 'actions' || !loadingRepositories || receivedRequest !== repositoryRequest) return;
    loadingRepositories = false;
    repositories = choices;
    ghRepositories = new Set(preferences.pipeline_gh_repositories);
    vercelProjects = new Map(Object.entries(preferences.pipeline_vercel_projects));
    if (!repositories.includes(repository)) {
      const saved = preferences.pipeline_repository;
      repository = repositories.includes(saved) ? saved : undefined;
    }
    const placeholder = node('option');
    placeholder.value = '';
    repositoryPicker.replaceChildren(placeholder, ...choices.map(name => {
      const option = node('option', name);
      option.value = name;
      return option;
    }));
    repositoryPicker.value = repository ?? '';
    render();
    load();
  };

  window.officePipelinePreferenceSaveFailed = () => {
    preferenceSaveFailed = true;
    render();
  };

  window.officeReceivePipeline = (snapshot, receivedRequest) => {
    if (!active || !busy || receivedRequest !== request) return;
    result = snapshot;
    if (pinnedRun && !snapshot.runs.some(run => run.id === pinnedRun)) pinnedRun = undefined;
    busy = false;
    render();
    const blocked = ['rateLimited', 'inaccessible', 'cliUnavailable', 'cliMissing'];
    const pollCI = snapshot.repository && ![snapshot.actionsError, snapshot.jobsError].some(error => blocked.includes(error));
    const pollReleases = snapshot.releases.some(release => !release.error || release.error === 'unavailable');
    if (pollCI || pollReleases) {
      timer = setTimeout(() => load(true), pollReleases || usesCLI() ? 30_000 : 180_000);
    }
  };

  return {
    render,
    setProjects(choices) {
      const key = JSON.stringify(choices);
      if (key === projectsKey) return;
      projectsKey = key;
      projects = new Map(choices);
      if (thread && !projects.has(thread)) {
        if (source === 'releases') reset();
        thread = undefined;
      }
      const placeholder = node('option');
      placeholder.value = '';
      workspace.replaceChildren(placeholder, ...choices.map(([id, label]) => {
        const option = node('option', label);
        option.value = id;
        return option;
      }));
      workspace.value = thread ?? '';
      workspace.disabled = !projects.size;
      render();
    },
    setActive(visible, preferred) {
      if (active === visible) return;
      active = visible;
      if (!active) {
        reset();
        return;
      }
      if (projects.has(preferred)) thread = preferred;
      workspace.value = thread ?? '';
      if (source === 'actions') discoverRepositories();
      else {
        render();
        load();
      }
    }
  };
};
