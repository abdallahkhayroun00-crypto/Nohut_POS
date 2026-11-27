// Per-operation permissions (spec V5.1 §20.3, §22.3). The catalogue is the SAME
// file the Windows POS, Android apps and server use. The client check only
// hides/disables controls; the server and the Windows POS enforce.
import catalogue from '../../../docs/contracts/v1/permissions.json';

export type Sensitivity = 'normal' | 'elevated' | 'ownerOnly';

export interface Operation {
  id: string;
  section: string;
  sensitivity: Sensitivity;
  defaults: string[];
  /** Which applications may request it. `['windows']` = Windows-only (§22.3). */
  clients: Client[];
}

export type Client = 'windows' | 'personel' | 'yonetici';

export const operations: readonly Operation[] = catalogue.operations as Operation[];

export function findOperation(id: string): Operation | undefined {
  return operations.find((op) => op.id === id);
}

/** Unknown operations deny; Windows-only operations deny on every remote
 *  client even for the owner; owner-only operations need the verified owner
 *  even if a grant was (wrongly) stored for someone else. */
export function canPerform(
  operationId: string,
  grants: ReadonlySet<string>,
  identity: { isOwner: boolean },
  client: Client,
): boolean {
  const op = findOperation(operationId);
  if (!op || !op.clients.includes(client)) return false;
  if (op.sensitivity === 'ownerOnly') return identity.isOwner;
  return identity.isOwner || grants.has(op.id);
}

export function operationsFor(section: string, client: Client): Operation[] {
  return operations.filter((op) => op.section === section && op.clients.includes(client));
}

/** Sections that exist only in the Windows POS (§22.3). */
export const windowsOnlySections: readonly string[] = catalogue.windowsOnlySections;
