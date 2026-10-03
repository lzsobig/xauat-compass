// Preserve the API handler's prepared-statement interface on Durable Object SQLite.
export function sqliteAdapter(storage){
  const sql=storage.sql;
  function prepare(query,values=[]){return {
    bind(...bound){return prepare(query,bound);},
    async first(){return sql.exec(query,...values).toArray()[0]||null;},
    async all(){return {results:sql.exec(query,...values).toArray()};},
    async run(){sql.exec(query,...values).toArray();return {meta:{changes:sql.exec('SELECT changes() AS n').toArray()[0].n}};},
    query,values
  };}
  return {prepare,async batch(statements){return storage.transactionSync(()=>statements.map(statement=>{sql.exec(statement.query,...statement.values).toArray();return {meta:{changes:sql.exec('SELECT changes() AS n').toArray()[0].n}};}));}};
}
