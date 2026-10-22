// Official identity for the prototype. Personal imports keep their own author.
export const prototypeBrand = Object.freeze({
  appName: '小七',
  officialDeveloper: '第七世界',
});

export function developerName(entry) {
  return entry.official || entry.author === '小七' || entry.author === 'OpenAI'
    ? prototypeBrand.officialDeveloper
    : entry.author || (entry.personal ? '你' : prototypeBrand.officialDeveloper);
}

// Merge current demo presentation data without dropping installs or personal work.
export function restoreCatalog(saved, defaults) {
  if (!Array.isArray(saved)) return defaults;
  const defaultsById = new Map(defaults.map(entry => [entry.id, entry]));
  const restored = saved.map(entry => {
    const current = defaultsById.get(entry.id);
    if (!current) return entry;
    defaultsById.delete(entry.id);
    return {
      ...current, ...entry,
      type: current.type,
      official: current.official,
      author: current.official ? prototypeBrand.officialDeveloper : entry.author,
    };
  });
  return [...restored, ...defaultsById.values()];
}
