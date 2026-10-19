// Test stub: tests set "objects" to { "obj": { method: (args) => reply } }.
let objects = {}, last_error = null;

function connect() {
	return {
		call: (obj, method, args) => {
			let fn = objects[obj]?.[method];

			last_error = fn ? null : 'Not found';

			return fn ? fn(args) : null;
		},
		error: () => { let e = last_error; last_error = null; return e; }
	};
}

return { connect, objects };
