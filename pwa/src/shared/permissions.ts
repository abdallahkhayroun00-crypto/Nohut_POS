// Per-operation permissions (spec V5.1 §20.3). The catalogue is the SAME
// file the Windows POS, Android apps and server use. The client check only
// hides/disables controls; the server and the Windows POS enforce.
import catalogue from '../../../docs/contracts/v1/permissions.json';

export type Sensitivity = 'normal' | 'elevated' | 'ownerOnly';

export interface Operation {
  id: string;
  section: string;
  sensitivity: Sensitivity;
  defaults: string[];
}

export const operations: readonly Operation[] = catalogue.operations as Operation[];

export function findOperation(id: string): Operation | undefined {
  return operations.find((op) => op.id === id);
}

/** Unknown operations deny; owner-only operations need the verified owner
 *  even if a grant was (wrongly) stored for someone else. */
export function canPerform(
  operationId: string,
  grants: ReadonlySet<string>,
  identity: { isOwner: boolean },
): boolean {
  const op = findOperation(operationId);
  if (!op) return false;
  if (op.sensitivity === 'ownerOnly') return identity.isOwner;
  return identity.isOwner || grants.has(op.id);
}

export function operationsFor(section: string): Operation[] {
  return operations.filter((op) => op.section === section);
}
